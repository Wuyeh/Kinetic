import Foundation
import WebKit
import XCTest
@testable import KineticSceneRuntime

final class SceneScriptTests: XCTestCase {
    private func binding(_ source: String, target: String = "alpha", value: SceneJSON = .number(1)) -> SceneScriptBinding {
        .init(id: "one:alpha", layerID: "one", target: target, source: source, value: value)
    }
    @MainActor
    func testWorkerRunsAuthoredUpdateWithMonotonicInput() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        let initial = try await executor.prepare([binding("export function update(value) { return engine.runtime / 10; }")])
        XCTAssertEqual(initial["one:alpha"], .number(1))
        let updated = try await executor.update(time: 3, delta: 1.0 / 30, cursor: .init(repeating: 0.5))
        XCTAssertEqual(updated["one:alpha"], .number(0.3))
    }
    @MainActor
    func testInfiniteUpdateTerminatesWorkerAndAllowsFreshExecutor() async throws {
        let executor = SceneScriptExecutor()
        _ = try await executor.prepare([binding("export function update(value) { while(true){} }")])
        let page = try XCTUnwrap(executor.webView)
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await executor.update(time: 1, delta: 1.0 / 30, cursor: .init(repeating: 0.5))
            XCTFail("infinite loop completed")
        } catch { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2) }
        XCTAssertTrue(executor.isDisposed); XCTAssertNil(executor.webView)
        let active = try await page.evaluateJavaScript("window.kineticSceneScripts.workerActive")
        XCTAssertEqual(active as? Bool, false, "Worker must actually terminate, not be quarantined")
        let fresh = SceneScriptExecutor()
        defer { fresh.dispose() }
        _ = try await fresh.prepare([binding("export function update(value) { return 0.5; }")])
        let result = try await fresh.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(result["one:alpha"], .number(0.5))
    }
    @MainActor
    func testInfiniteSetupHasDeadline() async throws {
        let executor = SceneScriptExecutor()
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await executor.prepare([binding("while(true){}")]); XCTFail("setup loop completed") }
        catch { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 7) }
        XCTAssertTrue(executor.isDisposed); XCTAssertNil(executor.webView)
    }
    @MainActor
    func testDisposeDuringInfiniteUpdateCancelsAndReleasesPage() async throws {
        let executor = SceneScriptExecutor()
        _ = try await executor.prepare([binding("export function update(value) { while(true){} }")])
        let page = try XCTUnwrap(executor.webView)
        let task = Task { try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5)) }
        try await Task.sleep(nanoseconds: 5_000_000)
        executor.dispose()
        do { _ = try await task.value; XCTFail("disposed update returned") } catch {}
        XCTAssertNil(executor.webView)
        let active = try await page.evaluateJavaScript("window.kineticSceneScripts.workerActive")
        XCTAssertEqual(active as? Bool, false)
    }
    @MainActor
    func testInvalidAndOversizedOutputDisposesExecutor() async throws {
        for source in ["export function update(v) { return -1; }",
                       "export function update(v) { return NaN; }",
                       "export function update(v) { return 'x'.repeat(40000); }"] {
            let executor = SceneScriptExecutor()
            _ = try await executor.prepare([binding(source)])
            do { _ = try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5)); XCTFail(source) } catch {}
            XCTAssertTrue(executor.isDisposed); XCTAssertNil(executor.webView)
        }
    }
    @MainActor
    func testWorkerHasNoDOMOrNativeBridgeAndCannotSpawnChildren() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        let source = """
        export function update(value) {
          if (typeof document !== 'undefined' || typeof webkit !== 'undefined') throw Error('bridge');
          let blocked = false; try { new Worker('blob:invalid'); } catch(e) { blocked = true; }
          return blocked ? 0.5 : -1;
        }
        """
        _ = try await executor.prepare([binding(source)])
        let result = try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(result["one:alpha"], .number(0.5))
    }
    @MainActor
    func testBindingSourceBudgetAndImportsRejectedBeforeWebView() async throws {
        for source in ["import x from './file.js';", String(repeating: " ", count: 262_145)] {
            let executor = SceneScriptExecutor()
            do { _ = try await executor.prepare([binding(source)]); XCTFail("unbounded source accepted") } catch {}
            XCTAssertNil(executor.webView)
        }
    }
    func testExactlyOnceCompletionIgnoresLateSuccess() async throws {
        let result = ScenePreparation<Int>()
        result.finish(.failure(CancellationError()))
        result.finish(.success(42))
        do { _ = try await withCheckedThrowingContinuation { result.install($0) }; XCTFail("late success replaced cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor
    func testAudioStereoBandsReachScriptWithoutCaptureAndCanReturnToSilence() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        let source = "const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16); export function update(v){return audio.average[0];}"
        _ = try await executor.prepare([binding(source)])
        let spectrum = try SceneAudioSpectrum(left: .init(repeating: 0.8, count: 64), right: .init(repeating: 0.2, count: 64))
        let result = try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5), audio: spectrum)
        XCTAssertEqual(result["one:alpha"]?.number ?? -1, 0.5, accuracy: 0.0001)
        let silent = try await executor.update(time: 2, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(silent["one:alpha"], .number(0))
    }
    @MainActor
    func testScriptTimersAdvanceOnlyWithSceneClock() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        _ = try await executor.prepare([binding("let result=0;setTimeout(()=>{result=0.5;},1000);export function update(v){return result;}")])
        try await Task.sleep(nanoseconds: 50_000_000)
        let before = try await executor.update(time: 0.5, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(before["one:alpha"], .number(0))
        let after = try await executor.update(time: 1.1, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(after["one:alpha"], .number(0.5))
    }
    func testAudioSpectrumRejectsUnboundedAndNonfiniteInputs() throws {
        XCTAssertThrowsError(try SceneAudioSpectrum(left: [0], right: [0]))
        XCTAssertThrowsError(try SceneAudioSpectrum(left: .init(repeating: .nan, count: 64), right: .init(repeating: 0, count: 64)))
    }
    @MainActor
    func testMicrotaskLoopAfterValidResponseTerminatesWithoutSceneUpdates() async throws {
        let executor = SceneScriptExecutor()
        var failure: Error?
        executor.onFailure = { failure = $0 }
        _ = try await executor.prepare([binding("export function init(v){Promise.resolve().then(()=>{while(true){}});return v;}")])
        let page = try XCTUnwrap(executor.webView)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while failure == nil, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertNotNil(failure)
        XCTAssertTrue(executor.isDisposed); XCTAssertNil(executor.webView)
        let active = try await page.evaluateJavaScript("window.kineticSceneScripts.workerActive")
        XCTAssertEqual(active as? Bool, false)
    }
    @MainActor
    func testAuthoredScriptPropertyValueAndBuilderDefault() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        var binding = binding("const properties=createScriptProperties().addSlider({name:'opacity',value:1}).addCombo({name:'choice',options:[{value:0.5}]}).finish();export function update(v){return properties.opacity*properties.choice;}")
        binding.properties = ["opacity": .number(0.4)]
        _ = try await executor.prepare([binding])
        let result = try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(result["one:alpha"]?.number ?? -1, 0.2, accuracy: 0.0001)
    }
    @MainActor
    func testWorkerConnectCSPBlocksEvenEmbeddedDataFetch() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        _ = try await executor.prepare([binding("let blocked=0;fetch('data:text/plain,hello').then(()=>{blocked=-1;},()=>{blocked=0.5;});export function update(v){return blocked;}")])
        try await Task.sleep(nanoseconds: 50_000_000)
        let result = try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(result["one:alpha"], .number(0.5))
    }

    @MainActor
    func testFrameWaitsForInFlightHealthProbeInsteadOfRejecting() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        _ = try await executor.prepare([binding("export function update(v){return 0.5;}")])
        let page = try XCTUnwrap(executor.webView)
        // Deterministically hold only the trusted health message in transit.
        _ = try await page.evaluateJavaScript("""
        window.healthInTransit=false;
        const post=Worker.prototype.postMessage;
        Worker.prototype.postMessage=function(message){
          if(message.kind==='health'){
            window.healthInTransit=true;
            setTimeout(()=>{post.call(this,message);window.healthInTransit=false;},80);
          }else post.call(this,message);
        };true;
        """)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var inTransit = false
        while !inTransit, ProcessInfo.processInfo.systemUptime < deadline {
            inTransit = try await page.evaluateJavaScript("window.healthInTransit") as? Bool == true
            if !inTransit { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        XCTAssertTrue(inTransit, "test must overlap the actual periodic health request")
        let result = try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5))
        XCTAssertEqual(result["one:alpha"], .number(0.5))
        XCTAssertFalse(executor.isDisposed)
    }

    @MainActor
    func testHealthyWorkerToleratesPageDeliveryDelayWithoutExtendingExecutionBudget() async throws {
        let executor = SceneScriptExecutor()
        defer { executor.dispose() }
        _ = try await executor.prepare([binding("export function update(v){return 0.5;}")])
        let page = try XCTUnwrap(executor.webView)
        let output: Any = try await withCheckedThrowingContinuation { continuation in
            page.callAsyncJavaScript("""
        const result=window.kineticSceneScripts.update({time:1,delta:0.03,cursor:{x:0.5,y:0.5},
          audio:{left:Array(64).fill(0),right:Array(64).fill(0)}});
        const end=performance.now()+80;
        while(performance.now()<end){}
        return await result;
        """, arguments: [:], in: nil, in: .page) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(output as? String, #"{"one:alpha":0.5}"#)
        XCTAssertFalse(executor.isDisposed)
    }

    @MainActor
    func testFiniteScriptOverExecutionBudgetStillFails() async throws {
        let executor = SceneScriptExecutor()
        _ = try await executor.prepare([binding("""
        export function update(v){const end=performance.now()+40;while(performance.now()<end){}return 0.5;}
        """)])
        do {
            _ = try await executor.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5))
            XCTFail("40 ms authored execution must not pass the 16 ms execution budget")
        } catch {}
        XCTAssertTrue(executor.isDisposed)
    }

    @MainActor
    func testOneInfiniteWorkerDoesNotStopAnotherScenesFramesOrHealthChecks() async throws {
        let bad = SceneScriptExecutor(), healthy = SceneScriptExecutor()
        defer { bad.dispose(); healthy.dispose() }
        _ = try await bad.prepare([binding("export function update(v){while(true){}}")])
        _ = try await healthy.prepare([binding("export function update(v){return 0.5;}")])
        var healthyFailure: Error?
        healthy.onFailure = { healthyFailure = $0 }
        let stalled = Task { try await bad.update(time: 1, delta: 0.03, cursor: .init(repeating: 0.5)) }
        for frame in 0..<60 {
            let result = try await healthy.update(time: Double(frame) / 30, delta: 1.0 / 30,
                                                  cursor: .init(repeating: 0.5))
            XCTAssertEqual(result["one:alpha"], .number(0.5))
            try await Task.sleep(nanoseconds: 33_000_000)
        }
        do { _ = try await stalled.value; XCTFail("infinite worker completed") } catch {}
        XCTAssertTrue(bad.isDisposed)
        XCTAssertFalse(healthy.isDisposed)
        XCTAssertNil(healthyFailure)
    }
}
