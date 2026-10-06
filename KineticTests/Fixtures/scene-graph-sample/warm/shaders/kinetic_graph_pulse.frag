uniform float g_Time;
void main() {
float pulse=0.65+0.35*sin(g_Time);
 float weight=0.0;
 for(int i=0;i<4;i++){weight+=0.25;
}
 gl_FragColor=vec4(vec3(0.92,0.35,0.12)*pulse*weight,1.0);
}
