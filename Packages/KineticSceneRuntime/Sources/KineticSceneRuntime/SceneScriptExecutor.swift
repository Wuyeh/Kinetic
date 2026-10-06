import Foundation
import WebKit

struct SceneScriptBinding: Sendable, Equatable {
    let id: String
    let layerID: String
    let target: String
    let source: String
    let value: SceneJSON
    var properties: [String: SceneJSON] = [:]

    var argument: [String: Any] {
        get throws {
            var seed: Any
            switch target {
            case "origin", "scale", "angles", "color":
                let value = try vector(value, fallback: SIMD3(repeating: target == "scale" || target == "color" ? 1 : 0))
                seed = ["x": value.x, "y": value.y, "z": value.z]
            case "alpha": seed = try scalar(value, fallback: 1)
            case "visible": seed = value.seed.bool ?? true
            default: throw SceneRuntimeError.unsupported("script binding: \(target)")
            }
            // Only declaration exports are supported. Module imports are never fetched by WebKit.
            guard source.range(of: #"\b(import|export\s+default)\b|export\s*\{"#, options: .regularExpression) == nil else {
                throw SceneRuntimeError.unsupported("SceneScript module import / export form")
            }
            let executable = source.replacingOccurrences(of: #"\bexport\s+(?=(?:function|const|let|var|class)\b)"#,
                with: "", options: .regularExpression)
            guard properties.count <= 64 else { throw SceneRuntimeError.budgetExceeded("SceneScript property count") }
            var authored: [String: Any] = [:]
            for (name, value) in properties {
                guard !name.isEmpty, name.utf8.count <= 128 else { throw SceneRuntimeError.malformed("SceneScript property name") }
                switch value.seed {
                case .number(let number):
                    guard number.isFinite, abs(number) <= 1_000_000 else { throw SceneRuntimeError.malformed("script property number") }
                    authored[name] = number
                case .bool(let boolean): authored[name] = boolean
                case .string(let string):
                    guard string.utf8.count <= 1024 else { throw SceneRuntimeError.budgetExceeded("script property string") }
                    authored[name] = string
                default: throw SceneRuntimeError.unsupported("SceneScript property value type")
                }
            }
            guard try JSONSerialization.data(withJSONObject: authored).count <= 4096 else {
                throw SceneRuntimeError.budgetExceeded("SceneScript authored property bytes")
            }
            return ["id": id, "source": executable, "value": seed, "properties": authored]
        }
    }

    func validateOutput(_ value: SceneJSON) throws {
        switch target {
        case "origin", "scale", "angles", "color":
            guard let fields = value.object, fields.keys.allSatisfy({ ["x", "y", "z"].contains($0) }),
                  let x = fields["x"]?.number, let y = fields["y"]?.number,
                  let z = fields["z"]?.number, [x, y, z].allSatisfy(\.isFinite) else {
                throw SceneRuntimeError.malformed("SceneScript vector result")
            }
            let bound: Double = target == "origin" ? 1_000_000 : target == "scale" ? 1_000 : 360_000
            guard [x, y, z].allSatisfy({ abs($0) <= bound }),
                  target != "angles" || (abs(x) < 0.0001 && abs(y) < 0.0001) else {
                throw SceneRuntimeError.unsupported("SceneScript vector range / 3D rotation")
            }
        case "alpha":
            guard let number = value.number, number.isFinite, (0...1).contains(number) else {
                throw SceneRuntimeError.malformed("SceneScript alpha result")
            }
        case "visible":
            guard value.bool != nil else { throw SceneRuntimeError.malformed("SceneScript visibility result") }
        default: throw SceneRuntimeError.unsupported("script binding: \(target)")
        }
    }
}

/// Authored JavaScript runs only inside a terminate-able Worker, never on a native thread
/// or in the trusted coordinator page. Each renderer owns and disposes its entire executor.
@MainActor
final class SceneScriptExecutor: NSObject, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private(set) var isDisposed = false
    private var loaded: ScenePreparation<Void>?
    private var pending: ScenePreparation<Any>?
    private var bindings: [SceneScriptBinding] = []
    private var generation: UInt64 = 0
    private var busy = false
    var onFailure: ((Error) -> Void)?
    private var healthTask: Task<Void, Never>?
    private var healthCompletion: ScenePreparation<Any>?

    func prepare(_ bindings: [SceneScriptBinding]) async throws -> [String: SceneJSON] {
        guard webView == nil, !isDisposed else { throw SceneRuntimeError.disposed }
        guard bindings.count <= 32, bindings.reduce(0, { $0 + $1.source.utf8.count }) <= 256 * 1_024 else {
            throw SceneRuntimeError.budgetExceeded("SceneScript source / bindings")
        }
        let arguments = try bindings.map { try $0.argument }
        self.bindings = bindings
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view; view.navigationDelegate = self; view.uiDelegate = self
        let completion = ScenePreparation<Void>()
        loaded = completion
        view.loadHTMLString(Self.html, baseURL: nil)
        do {
            try await deadline(completion, seconds: 5)
            loaded = nil
            let result = try await request("return await window.kineticSceneScripts.prepare(bindings);",
                arguments: ["bindings": arguments], seconds: 2)
            watchHealth()
            return result
        } catch { dispose(); throw error }
    }

    private func watchHealth() {
        guard let view = webView else { return }
        let completion = ScenePreparation<Any>()
        healthCompletion = completion
        view.callAsyncJavaScript("return await window.kineticSceneScripts.failureSignal();", arguments: [:], in: nil, in: .page) {
            completion.finish($0)
        }
        healthTask = Task { [weak self] in
            do {
                let value = try await withCheckedThrowingContinuation { completion.install($0) }
                guard let self, !self.isDisposed else { return }
                let failure = SceneRuntimeError.graphics((value as? String) ?? "SceneScript Worker stopped")
                let callback = self.onFailure
                self.dispose(); callback?(failure)
            } catch {
                guard let self, !self.isDisposed else { return }
                let callback = self.onFailure
                self.dispose(); callback?(error)
            }
        }
    }

    func update(time: Double, delta: Double, cursor: SIMD2<Float>, audio: SceneAudioSpectrum = .silence) async throws -> [String: SceneJSON] {
        guard time.isFinite, delta.isFinite, delta >= 0, cursor.x.isFinite, cursor.y.isFinite else {
            throw SceneRuntimeError.malformed("SceneScript frame input")
        }
        return try await request("return await window.kineticSceneScripts.update(input);",
            arguments: ["input": ["time": time, "delta": delta, "cursor": ["x": cursor.x, "y": cursor.y],
                                  "audio": ["left": audio.left, "right": audio.right]]],
            seconds: 1)
    }

    private func request(_ body: String, arguments: [String: Any], seconds: Double) async throws -> [String: SceneJSON] {
        guard let view = webView, !isDisposed else { throw SceneRuntimeError.disposed }
        guard !busy else { throw SceneRuntimeError.malformed("concurrent SceneScript frame") }
        busy = true
        let token = generation, completion = ScenePreparation<Any>()
        pending = completion
        defer { busy = false; pending = nil }
        view.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in completion.finish(result) }
        do {
            let output = try await deadline(completion, seconds: seconds)
            guard !isDisposed, generation == token else { throw SceneRuntimeError.disposed }
            guard let string = output as? String, string.utf8.count <= 32 * 1_024 else {
                throw SceneRuntimeError.budgetExceeded("SceneScript output")
            }
            var limits = SceneLimits()
            limits.maximumJSONBytes = 32 * 1_024; limits.maximumJSONDepth = 8; limits.maximumJSONNodes = 512
            let json = try SceneJSON.parse(Data(string.utf8), limits: limits)
            guard let values = json.object, values.count == bindings.count else {
                throw SceneRuntimeError.malformed("SceneScript binding results")
            }
            for binding in bindings {
                guard let value = values[binding.id] else { throw SceneRuntimeError.malformed("missing script result") }
                try binding.validateOutput(value)
            }
            return values
        } catch { dispose(); throw error }
    }

    private func deadline<T>(_ completion: ScenePreparation<T>, seconds: Double) async throws -> T {
        let timer = Task {
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            completion.finish(.failure(SceneRuntimeError.budgetExceeded("SceneScript host deadline")))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { completion.install($0) }
        }, onCancel: { completion.finish(.failure(CancellationError())) })
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true; generation &+= 1
        loaded?.finish(.failure(CancellationError())); loaded = nil
        pending?.finish(.failure(CancellationError())); pending = nil
        healthCompletion?.finish(.failure(CancellationError())); healthCompletion = nil
        healthTask?.cancel(); healthTask = nil; onFailure = nil
        // The trusted page can still execute this while its Worker is stuck in an infinite loop.
        webView?.evaluateJavaScript("window.kineticSceneScripts?.dispose();", completionHandler: nil)
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView = nil; bindings = []
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.finish(.success(())) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loaded?.finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loaded?.finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded?.finish(.failure(SceneRuntimeError.graphics("SceneScript WebContent terminated")))
        pending?.finish(.failure(SceneRuntimeError.graphics("SceneScript WebContent terminated")))
        dispose()
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    private static let worker = #"""
    'use strict';
    const send = self.postMessage.bind(self), serialize = JSON.stringify.bind(JSON), compile = Function;
    const clock = performance.now.bind(performance);
    for (const key of ['Worker','SharedWorker','importScripts']) {
      Object.defineProperty(self,key,{value:()=>{throw new Error('Unavailable Scene API: '+key)},writable:false,configurable:false});
    }
    class Vec3 {
      constructor(x=0,y=x,z=x){this.x=x;this.y=y;this.z=z}
      copy(){return new Vec3(this.x,this.y,this.z)}
      add(v){this.x+=v.x;this.y+=v.y;this.z+=v.z;return this}
      subtract(v){this.x-=v.x;this.y-=v.y;this.z-=v.z;return this}
      multiply(v){if(typeof v==='number'){this.x*=v;this.y*=v;this.z*=v}else{this.x*=v.x;this.y*=v.y;this.z*=v.z}return this}
    }
    class Vec2 extends Vec3 {constructor(x=0,y=x){super(x,y,0)}}
    let input={time:0,delta:0,cursor:{x:0.5,y:0.5},audio:{left:Array(64).fill(0),right:Array(64).fill(0)}}, entries=[];
    const buffers=[],timers=new Map();let nextTimer=0;
    function timer(callback,delay,interval,args){
      if(typeof callback!=='function'||timers.size>=256)throw Error('SceneScript timer budget');
      const seconds=Math.max(interval?0.016:0,Math.min(3600,Number(delay)/1000||0));
      const id=++nextTimer;timers.set(id,{callback,args,when:input.time+seconds,interval:interval?seconds:0});return id;
    }
    for(const [name,value] of Object.entries({
      setTimeout:(callback,delay,...args)=>timer(callback,delay,false,args),
      setInterval:(callback,delay,...args)=>timer(callback,delay,true,args),
      clearTimeout:id=>timers.delete(id),clearInterval:id=>timers.delete(id)}))
      Object.defineProperty(self,name,{value,writable:false,configurable:false});
    function advanceTimers(){
      let count=0;
      for(const [id,t] of [...timers]){
        if(t.when>input.time)continue;
        if(++count>256)throw Error('SceneScript timer callback budget');
        if(t.interval)t.when=input.time+t.interval;else timers.delete(id);
        t.callback(...t.args);
      }
    }
    function registerAudioBuffers(bands){
      if(![16,32,64].includes(bands))bands=16;
      if(buffers.length>=16)throw Error('SceneScript audio registration budget');
      const buffer=Object.freeze({left:Object.seal(Array(bands).fill(0)),right:Object.seal(Array(bands).fill(0)),average:Object.seal(Array(bands).fill(0))});
      buffers.push({bands,buffer});return buffer;
    }
    function refreshAudio(){
      for(const {bands,buffer} of buffers){
        const group=64/bands;
        for(let i=0;i<bands;i++){
          let left=0,right=0;
          for(let j=0;j<group;j++){left+=input.audio.left[i*group+j];right+=input.audio.right[i*group+j]}
          buffer.left[i]=left/group;buffer.right[i]=right/group;buffer.average[i]=(left+right)/(2*group);
        }
      }
    }
    const shared=Object.create(null);
    const engine=Object.freeze({get runtime(){return input.time},get frametime(){return input.delta},
      get mousePosition(){return new Vec2(input.cursor.x,input.cursor.y)},get isPaused(){return false},
      AUDIO_RESOLUTION_16:16,AUDIO_RESOLUTION_32:32,AUDIO_RESOLUTION_64:64,registerAudioBuffers,
      getFrequency:index=>Number.isInteger(index)&&index>=0&&index<64?(input.audio.left[index]+input.audio.right[index])/2:0,
      getFrequencies:()=>input.audio.left.map((value,index)=>(value+input.audio.right[index])/2)});
    function createScriptProperties(overrides){
      const values=Object.create(null), builder={};
      for(const kind of ['Slider','Checkbox','Color','Text','Combo']) builder['add'+kind]=function(o){
        if(!o||typeof o.name!=='string'||Object.keys(values).length>=64)throw Error('Script property declaration');
        let value=o.value!==undefined?o.value:o.options?.[0]?.value;
        if(Object.prototype.hasOwnProperty.call(overrides,o.name)){
          value=overrides[o.name];
          if(kind==='Slider'){value=Number(value);if(!Number.isFinite(value))throw Error('Script slider value')}
          if(kind==='Checkbox'){if(typeof value!=='boolean')throw Error('Script checkbox value')}
          if(kind==='Text'){if(typeof value!=='string')throw Error('Script text value')}
          if(kind==='Color'){
            const components=typeof value==='string'?value.trim().split(/\s+/).map(Number):null;
            if(!components||components.length!==3||components.some(v=>!Number.isFinite(v)))throw Error('Script color value');
            value=new Vec3(...components);
          }
        }
        values[o.name]=value;return builder;
      };
      builder.finish=()=>values;return builder;
    }
    self.onmessage=e=>{
      const message=e.data;
      const started=clock();
      try {
        if(message.kind==='health'){send({id:message.id,ok:true,json:'{}'});return}
        if(message.kind==='prepare'){
          entries=message.bindings.map(b=>{
            const api=new compile('engine','Vec2','Vec3','shared','createScriptProperties',b.source+
              '\n;return {init:typeof init==="function"?init:null,update:typeof update==="function"?update:null};')
              (engine,Vec2,Vec3,shared,()=>createScriptProperties(b.properties||Object.create(null)));
            let value=b.value;
            if(value && typeof value==='object') value=new Vec3(value.x,value.y,value.z);
            if(api.init){const initial=api.init(value);if(initial!==undefined)value=initial}
            return {id:b.id,api,value};
          });
        } else if(message.kind==='update'){
          input=message.input;
          refreshAudio();advanceTimers();
          for(const entry of entries) if(entry.api.update){const value=entry.api.update(entry.value);if(value!==undefined)entry.value=value}
        }
        const result=Object.create(null);for(const entry of entries)result[entry.id]=entry.value;
        const json=serialize(result);if(json.length>32768)throw new Error('SceneScript output budget');
        // Measure authored execution here. Page/Worker delivery delays are not script CPU time.
        if(clock()-started>(message.kind==='prepare'?1000:16))throw Error('SceneScript execution budget exceeded');
        send({id:message.id,ok:true,json});
      }catch(error){send({id:message.id,ok:false,error:String(error).slice(0,1024)})}
    };
    """#

    private static var html: String {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: [worker]), encoding: .utf8)!
        let source = String(encoded.dropFirst().dropLast()).replacingOccurrences(of: "<", with: "\\u003c")
        return """
        <!doctype html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; worker-src blob:; connect-src 'none'; frame-src 'none'; object-src 'none';">
        <script>
        (()=>{'use strict';let worker=null,pending=null,sequence=0,failed=false,healthTimer=null;const failureObservers=[];
          function fail(error){
            failed=true;if(healthTimer){clearInterval(healthTimer);healthTimer=null}
            if(worker){worker.terminate();worker=null}
            if(pending){clearTimeout(pending.timer);const reject=pending.reject;pending=null;reject(error)}
            for(const resolve of failureObservers.splice(0))resolve(String(error).slice(0,1024));
          }
          function request(kind,data,budget){
            if(failed||!worker)return Promise.reject(new Error('SceneScript disposed'));
            // A periodic health message can already be in flight when a native frame arrives.
            // Wait for that callback-free probe; never reject a valid frame because of our own probe.
            if(pending&&pending.kind==='health'&&kind!=='health')
              return pending.promise.then(()=>request(kind,data,budget));
            if(pending)return Promise.reject(new Error('SceneScript frame already in flight'));
            const promise=new Promise((resolve,reject)=>{
              const id=++sequence,timer=setTimeout(()=>fail(new Error('SceneScript '+kind+' deadline exceeded')),Math.max(250,budget));
              pending={id,kind,resolve,reject,timer,promise:null};worker.postMessage({id,kind,...data});
            });
            pending.promise=promise;return promise;
          }
          window.kineticSceneScripts=Object.freeze({
            get workerActive(){return worker!==null},
            failureSignal(){return failed?Promise.resolve('SceneScript stopped'):new Promise(resolve=>failureObservers.push(resolve))},
            prepare(bindings){
              if(worker||failed)throw new Error('SceneScript already prepared');
              const url=URL.createObjectURL(new Blob([\(source)],{type:'text/javascript'}));
              worker=new Worker(url);URL.revokeObjectURL(url);
              worker.onmessage=e=>{
                if(!pending||e.data.id!==pending.id)return;
                if(!e.data.ok){fail(new Error(e.data.error||'SceneScript error'));return}
                if(typeof e.data.json!=='string'||e.data.json.length>32768){fail(new Error('SceneScript result budget'));return}
                const result=pending;pending=null;clearTimeout(result.timer);result.resolve(e.data.json);
              };
              worker.onerror=()=>fail(new Error('SceneScript Worker error'));
              // Health checks execute no authored callbacks and advance no scene clock.
              // They catch a microtask loop started after a valid response, including while paused.
              healthTimer=setInterval(()=>{
                if(!worker||pending||failed)return;
                request('health',{},16).catch(()=>{});
              },250);
              return request('prepare',{bindings},1000);
            },
            update(input){return request('update',{input},16)},
            dispose(){fail(new Error('SceneScript disposed'))}
          });
        })();
        </script>
        """
    }
}
