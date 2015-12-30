///////////////////////////////////////////////////////////////////////////////
// CUDA Kernels
///////////////////////////////////////////////////////////////////////////////

#include <GL/glew.h>
#include <GL/freeglut.h>
#include <cuda_gl_interop.h>
#include <timer.h>               // timing functions
#include <helper_functions.h>    // includes cuda.h and cuda_runtime_api.h
#include <helper_cuda.h>         // helper functions for CUDA error check
#include <helper_cuda_gl.h>
#include <thrust/device_ptr.h>
#include <thrust/sort.h>
#include <helper_math.h>

#define     DIM    256
#define     N    DIM-2

// Get 1d index from 2d coords
//
__device__ int IX( int x, int y) {
  if (x >= DIM) x = 0;
  if (x < 0) x = DIM-1;
  if (y >= DIM) y = 0;
  if (y < 0) y = DIM-1;
  return x + (y * blockDim.x * gridDim.x);
}

__device__ int getX() {
  return threadIdx.x + (blockIdx.x * blockDim.x);
}

__device__ int getY() {
  return threadIdx.y + (blockIdx.y * blockDim.y);
}

// Set boundary conditions
__device__ void set_bnd( int b, int x, int y, float *field) {
  int sz = DIM*DIM;
  int id = IX(x,y);

  if (x==0)       field[id] = b==1 ? -1*field[IX(1,y)] : field[IX(1,y)];
  if (x==DIM-1)   field[id] = b==1 ? -1*field[IX(DIM-2,y)] : field[IX(DIM-2,y)];
  if (y==0)       field[id] = b==2 ? -1*field[IX(x,1)] : field[IX(x,1)];
  if (y==DIM-1)   field[id] = b==2 ? -1*field[IX(x,DIM-2)] : field[IX(x,DIM-2)];

  if (id == 0)      field[id] = 0.5*(field[IX(1,0)]+field[IX(0,1)]);  // southwest
  if (id == sz-DIM) field[id] = 0.5*(field[IX(1,DIM-1)]+field[IX(0, DIM-2)]); // northwest
  if (id == DIM-1)  field[id] = 0.5*(field[IX(DIM-2,0)]+field[IX(DIM-1,1)]); // southeast
  if (id == sz-1)   field[id] = 0.5*(field[IX(DIM-2,DIM-1)]+field[IX(DIM-1,DIM-2)]); // northeast
}

__global__ void SetBoundary( int b, float *field ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  set_bnd(b, x, y, field);
}

// Draw a square
//
__global__ void DrawSquare( float *field ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  // q1. draws a square
  float posX = (float)x/DIM;
  float posY = (float)y/DIM;
  if ( posX < .75 && posX > .45 && posY < .51 && posY > .48 ) {
    field[id] = 1.0;
  }
}

__global__ void ClearArray( float4 *field, float value ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  field[id] = make_float4(value,value,value,1.);
}

__global__ void ClearArray( float *field, float value ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  field[id] = value;
}

__global__ void GetFromUI ( float * field, int x_coord, int y_coord, float value, float dt ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  if (x>x_coord-5 && x<x_coord+5 && y>y_coord-5 && y<y_coord+5){
    field[id] = value;
  }
  else return;

}

__global__ void InitVelocity ( float * field ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);
  float s = sin((float(x)/float(N)) * 3.1459 * 4);
  field[id] += s;
}

__global__ void AddStaticVelocity ( float * field, float value, float dt ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  float dF = float(DIM);
  float yF = float(y);
  float i0 = abs(0.5 - (yF/dF)) * -2.0;
  i0 = i0+1.0;

  // i0 = yF/dF;
  // if (y > .4 && y < .6) {
    // field[id] += (i0 * dt) * value;
    field[id] += sin(((yF/dF) * 3.14159 * value))*dt;
  // }
}

///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////

__global__ void AddSource ( float * field, float * source, float dt ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  field[id] += (dt * source[id]);
}

__global__ void LinSolve( int b, float *field, float *field0, float a, float c) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  if (x>0 && x<DIM-1 && y>0 && y<DIM-1){
    field[id] = (field0[id] + a*(field[IX(x-1,y)] + field[IX(x+1,y)] + field[IX(x,y-1)] + field[IX(x,y+1)])) / c;
  }
  // set_bnd( b, x, y, field );
}

__global__ void Advect ( int b, float *field, float * field0, float *u, float *v, float dt ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  int i0, j0, i1, j1;
  float x_vel, y_vel, s0, t0, s1, t1, dt0;
  dt0 = dt*float(N);

  if (x>0 && x<DIM-1 && y>0 && y<DIM-1){
    x_vel = x - dt0 * u[id];
    y_vel = y - dt0 * v[id];

    if (x_vel < 0.5) x_vel = 0.5;
    if (x_vel > N+0.5) x_vel = N+0.5;
    i0 = int(x_vel);
    i1 = i0+1;

    if (y_vel < 0.5) y_vel = 0.5;
    if (y_vel > N+0.5) y_vel = N+0.5;
    j0 = int(y_vel);
    j1 = j0+1;

    s1 = x_vel-i0;
    s0 = 1-s1;
    t1 = y_vel-j0;
    t0 = 1-t1;

    field[id] = s0*((t0*field0[IX(i0,j0)]) + (t1*field0[IX(i0,j1)])) +
                s1*((t0*field0[IX(i1,j0)]) + (t1*field0[IX(i1,j1)]));
  }
  // set_bnd(b, x, y, field );
}

__global__ void Project ( float * u, float * v, float * p, float * div ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  if (x>0 && x<DIM-1 && y>0 && y<DIM-1){
    div[id] = -0.5 *(u[IX(x+1,y)] - u[IX(x-1,y)] + v[IX(x,y+1)] - v[IX(x,y-1)]) / float(N);
    p[id] = 0;
  }
}

__global__ void ProjectFinish ( float * u, float * v, float * p, float * div ) {
  int x = getX();
  int y = getY();
  int id = IX(x,y);

  if (x>0 && x<DIM-1 && y>0 && y<DIM-1){
    u[id] -= (0.5 * float(N) * (p[IX(x+1,y)] - p[IX(x-1,y)]));
    v[id] -= (0.5 * float(N) * (p[IX(x,y+1)] - p[IX(x,y-1)]));
  }
  // set_bnd ( 1, x, y, u );
  // set_bnd ( 2, x, y, v );
}

//
// really dont like that i have to do this...
//
__global__ void MakeColor( float *data, float4 *_toDisplay) {
  int x = getX();
  int y = getY();
  int offset = x + y * blockDim.x * gridDim.x;

  float Cd = data[offset];
  _toDisplay[offset] = make_float4(Cd, Cd, Cd, 1.0);
}
