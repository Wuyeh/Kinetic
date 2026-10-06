attribute vec3 a_Position;
uniform mat4 g_ModelViewProjectionMatrix;
void main() {
 gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1.0);
}
