/* 
   Copyright (C) 2010,2011,2012,2013,2014 The ESPResSo project

   This file is part of ESPResSo.
  
   ESPResSo is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.
   
   ESPResSo is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.
   
   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

/** \file p3m_gpu_cuda.cu
 *
 * Cuda (.cu) file for the P3M electrostatics method.
 * Header file \ref p3m_gpu.hpp .
 */ 

#include <stdio.h>
#include <stdlib.h>
#include <cuda.h>

#include <cufft.h>
#include "cuda_interface.hpp"
#include "cuda_utils.hpp"
#include "config.hpp"
#include "p3m_gpu.hpp"
#include "utils.hpp"
#include "EspressoSystemInterface.hpp"

#ifdef ELECTROSTATICS

struct dummytypename {
  CUFFT_TYPE_COMPLEX *charge_mesh;
  CUFFT_TYPE_COMPLEX *force_mesh_x;
  CUFFT_TYPE_COMPLEX *force_mesh_y;
  CUFFT_TYPE_COMPLEX *force_mesh_z;
  REAL_TYPE *G_hat;
  REAL_TYPE *G_hat_host;
  cufftHandle fft_plan;
  int cao, mesh;
  REAL_TYPE alpha;
  int npart;
  REAL_TYPE box;
} p3m_gpu_data;

static char p3m_gpu_data_initialized = 0;

#define SQR(A) ((A)*(A))

extern __shared__ float weights[];

__host__ __device__ inline double csinc(double d)
{
#define epsi 0.1

#define c2 -0.1666666666667e-0
#define c4  0.8333333333333e-2
#define c6 -0.1984126984127e-3
#define c8  0.2755731922399e-5

  double PId = PI*d, PId2;

  if (fabs(d)>epsi)
    return sin(PId)/PId;
  else {
    PId2 = SQR(PId);
    return 1.0 + PId2*(c2+PId2*(c4+PId2*(c6+PId2*c8)));
  }
}

template<int cao_value>
__device__ REAL_TYPE caf(int i, REAL_TYPE x) {
  switch (cao_value) {
  case 1 : return 1.0;
  case 2 : {
    switch (i) {
    case 0: return 0.5-x;
    case 1: return 0.5+x;
    default:
      return 0.0;
    }
  } 
  case 3 : { 
    switch (i) {
    case 0: return 0.5*SQR(0.5 - x);
    case 1: return 0.75 - SQR(x);
    case 2: return 0.5*SQR(0.5 + x);
    default:
      return 0.0;
    }
  case 4 : { 
    switch (i) {
    case 0: return ( 1.0+x*( -6.0+x*( 12.0-x* 8.0)))/48.0;
    case 1: return (23.0+x*(-30.0+x*(-12.0+x*24.0)))/48.0;
    case 2: return (23.0+x*( 30.0+x*(-12.0-x*24.0)))/48.0;
    case 3: return ( 1.0+x*(  6.0+x*( 12.0+x* 8.0)))/48.0;
    default:
      return 0.0;
    }
  }
  case 5 : {
    switch (i) {
    case 0: return (  1.0+x*( -8.0+x*(  24.0+x*(-32.0+x*16.0))))/384.0;
    case 1: return ( 19.0+x*(-44.0+x*(  24.0+x*( 16.0-x*16.0))))/ 96.0;
    case 2: return (115.0+x*       x*(-120.0+x*       x*48.0))  /192.0;
    case 3: return ( 19.0+x*( 44.0+x*(  24.0+x*(-16.0-x*16.0))))/ 96.0;
    case 4: return (  1.0+x*(  8.0+x*(  24.0+x*( 32.0+x*16.0))))/384.0;
    default:
      return 0.0;
    }
  }
  case 6 : {
    switch (i) {
    case 0: return (  1.0+x*( -10.0+x*(  40.0+x*( -80.0+x*(  80.0-x* 32.0)))))/3840.0;
    case 1: return (237.0+x*(-750.0+x*( 840.0+x*(-240.0+x*(-240.0+x*160.0)))))/3840.0;
    case 2: return (841.0+x*(-770.0+x*(-440.0+x*( 560.0+x*(  80.0-x*160.0)))))/1920.0;
    case 3: return (841.0+x*(+770.0+x*(-440.0+x*(-560.0+x*(  80.0+x*160.0)))))/1920.0;
    case 4: return (237.0+x*( 750.0+x*( 840.0+x*( 240.0+x*(-240.0-x*160.0)))))/3840.0;
    case 5: return (  1.0+x*(  10.0+x*(  40.0+x*(  80.0+x*(  80.0+x* 32.0)))))/3840.0;
    default:
      return 0.0;
    }
  }
  case 7 : {
    switch (i) {
    case 0: return (    1.0+x*(   -12.0+x*(   60.0+x*( -160.0+x*(  240.0+x*(-192.0+x* 64.0))))))/46080.0;
    case 1: return (  361.0+x*( -1416.0+x*( 2220.0+x*(-1600.0+x*(  240.0+x*( 384.0-x*192.0))))))/23040.0;
    case 2: return (10543.0+x*(-17340.0+x*( 4740.0+x*( 6880.0+x*(-4080.0+x*(-960.0+x*960.0))))))/46080.0;
    case 3: return ( 5887.0+x*          x*(-4620.0+x*         x*( 1680.0-x*        x*320.0)))   /11520.0;
    case 4: return (10543.0+x*( 17340.0+x*( 4740.0+x*(-6880.0+x*(-4080.0+x*( 960.0+x*960.0))))))/46080.0;
    case 5: return (  361.0+x*(  1416.0+x*( 2220.0+x*( 1600.0+x*(  240.0+x*(-384.0-x*192.0))))))/23040.0;
    case 6: return (    1.0+x*(    12.0+x*(   60.0+x*(  160.0+x*(  240.0+x*( 192.0+x* 64.0))))))/46080.0;
    default:
      return 0.0;
    }
  }
  }}
  return 0.0;
}


__host__ __device__ void static Aliasing_sums_ik ( int cao, REAL_TYPE box, REAL_TYPE alpha, int mesh, int NX, int NY, int NZ,
						   REAL_TYPE *Zaehler, REAL_TYPE *Nenner ) {
  REAL_TYPE S1,S2,S3;
  REAL_TYPE fak1,fak2,zwi;
  int    MX,MY,MZ;
  REAL_TYPE NMX,NMY,NMZ;
  REAL_TYPE NM2;
  REAL_TYPE expo, TE;
  REAL_TYPE Leni = 1.0/box;

  fak1 = 1.0/ ( REAL_TYPE ) mesh;
  fak2 = SQR ( PI/ ( alpha ) );

  Zaehler[0] = Zaehler[1] = Zaehler[2] = *Nenner = 0.0;

  for ( MX = -P3M_BRILLOUIN; MX <= P3M_BRILLOUIN; MX++ ) {
    NMX = ( ( NX > mesh/2 ) ? NX - mesh : NX ) + mesh*MX;
    S1 = pow ( csinc(fak1*NMX ), 2*cao );
    for ( MY = -P3M_BRILLOUIN; MY <= P3M_BRILLOUIN; MY++ ) {
      NMY = ( ( NY > mesh/2 ) ? NY - mesh : NY ) + mesh*MY;
      S2   = S1*pow ( csinc (fak1*NMY ), 2*cao );
      for ( MZ = -P3M_BRILLOUIN; MZ <= P3M_BRILLOUIN; MZ++ ) {
	NMZ = ( ( NZ > mesh/2 ) ? NZ - mesh : NZ ) + mesh*MZ;
	S3   = S2*pow ( csinc( fak1*NMZ ), 2*cao );

	NM2 = SQR ( NMX*Leni ) + SQR ( NMY*Leni ) + SQR ( NMZ*Leni );
	*Nenner += S3;

	expo = fak2*NM2;
	TE = exp ( -expo );
	zwi  = S3 * TE/NM2;
	Zaehler[0] += NMX*zwi*Leni;
	Zaehler[1] += NMY*zwi*Leni;
	Zaehler[2] += NMZ*zwi*Leni;
      }
    }
  }
}

/* Calculate influence function */
#if 1
// host version, not used anywhere
void static calculate_influence_function ( int cao, int mesh, REAL_TYPE box, REAL_TYPE alpha, REAL_TYPE *G_hat ) {

  int    NX,NY,NZ;
  REAL_TYPE Dnx,Dny,Dnz;
  REAL_TYPE Zaehler[3]={0.0,0.0,0.0},Nenner=0.0;
  REAL_TYPE zwi;
  int ind = 0;
  REAL_TYPE Leni = 1.0/box;

  for ( NX=0; NX<mesh; NX++ ) {
    for ( NY=0; NY<mesh; NY++ ) {
      for ( NZ=0; NZ<mesh; NZ++ ) {
	ind = NX*mesh*mesh + NY * mesh + NZ;
	  
	if ( ( NX==0 ) && ( NY==0 ) && ( NZ==0 ) )
	  G_hat[ind]=0.0;
	else if ( ( NX% ( mesh/2 ) == 0 ) && ( NY% ( mesh/2 ) == 0 ) && ( NZ% ( mesh/2 ) == 0 ) )
	  G_hat[ind]=0.0;
	else {
	  Aliasing_sums_ik ( cao, box, alpha, mesh, NX, NY, NZ, Zaehler, &Nenner );
		  
	  Dnx = ( NX > mesh/2 ) ? NX - mesh : NX;
	  Dny = ( NY > mesh/2 ) ? NY - mesh : NY;
	  Dnz = ( NZ > mesh/2 ) ? NZ - mesh : NZ;
	    
	  zwi  = Dnx*Zaehler[0]*Leni + Dny*Zaehler[1]*Leni + Dnz*Zaehler[2]*Leni;
	  zwi /= ( ( SQR ( Dnx*Leni ) + SQR ( Dny*Leni ) + SQR ( Dnz*Leni ) ) * SQR ( Nenner ) );
	  G_hat[ind] = 2.0 * zwi / PI;
	}
      }
    }
  }
}
#endif

__global__ void calculate_influence_function_device ( int cao, int mesh, REAL_TYPE box, REAL_TYPE alpha, REAL_TYPE *G_hat ) {

  int    NX,NY,NZ;
  REAL_TYPE Dnx,Dny,Dnz;
  REAL_TYPE Zaehler[3]={0.0,0.0,0.0},Nenner=0.0;
  REAL_TYPE zwi;
  int ind = 0;
  REAL_TYPE Leni = 1.0/box;

  NX = blockDim.x * blockIdx.x + threadIdx.x;
  NY = threadIdx.y;
  NZ = threadIdx.z;

  if(NX >= mesh)
    return;

  ind = NX*mesh*mesh + NY * mesh + NZ;
	  
  if ( ( NX==0 ) && ( NY==0 ) && ( NZ==0 ) )
    G_hat[ind]=0.0;
  else if ( ( NX% ( mesh/2 ) == 0 ) && ( NY% ( mesh/2 ) == 0 ) && ( NZ% ( mesh/2 ) == 0 ) )
    G_hat[ind]=0.0;
  else {
    Aliasing_sums_ik ( cao, box, alpha, mesh, NX, NY, NZ, Zaehler, &Nenner );
		  
    Dnx = ( NX > mesh/2 ) ? NX - mesh : NX;
    Dny = ( NY > mesh/2 ) ? NY - mesh : NY;
    Dnz = ( NZ > mesh/2 ) ? NZ - mesh : NZ;
	    
    zwi  = Dnx*Zaehler[0]*Leni + Dny*Zaehler[1]*Leni + Dnz*Zaehler[2]*Leni;
    zwi /= ( ( SQR ( Dnx*Leni ) + SQR ( Dny*Leni ) + SQR ( Dnz*Leni ) ) * SQR ( Nenner ) );
    G_hat[ind] = 2.0 * zwi / PI;
  }
}


//NOTE :if one wants to use the function below it requires cuda compute capability 1.3
#ifdef _P3M_GPU_REAL_DOUBLE
__device__ double atomicAdd (double* address, double val)
{
  unsigned long long int* address_as_ull =
    (unsigned long long int*)address;
  unsigned long long int old = *address_as_ull, assumed;
  do {
    assumed = old;
    old = atomicCAS(address_as_ull, assumed,
		    __double_as_longlong(val +
					 __longlong_as_double(assumed)));
  } while (assumed != old);
  return __longlong_as_double(old);
}
#endif

/** atomic add function for several cuda architectures 
 */

#if !defined __CUDA_ARCH__ || __CUDA_ARCH__ >= 200
#define THREADS_PER_BLOCK 1024
#else
#define THREADS_PER_BLOCK 512
#endif

#if !defined __CUDA_ARCH__ || __CUDA_ARCH__ >= 200 // for Fermi, atomicAdd supports floats
//atomicAdd supports floats already, do nothing
#elif __CUDA_ARCH__ >= 110
#warning Using slower atomicAdd emulation
__device__ inline void atomicAdd(float* address, float value){
  // float-atomic-add from 
  // [url="http://forums.nvidia.com/index.php?showtopic=158039&view=findpost&p=991561"]
  float old = value;
  while ((old = atomicExch(address, atomicExch(address, 0.0f)+old))!=0.0f);
}
#else
#error I need at least compute capability 1.1
#endif

__global__ void apply_diff_op( CUFFT_TYPE_COMPLEX *mesh, const int mesh_size, 
			       CUFFT_TYPE_COMPLEX *force_mesh_x,  CUFFT_TYPE_COMPLEX *force_mesh_y, CUFFT_TYPE_COMPLEX *force_mesh_z, 
			       const REAL_TYPE box ) {
  const int linear_index = mesh_size*mesh_size*blockIdx.x + mesh_size * blockIdx.y + threadIdx.x;

  if(threadIdx.x < mesh_size) {
    int n;
    n = ( threadIdx.x == mesh_size/2 ) ? 0.0 : threadIdx.x;
    n = ( n > mesh_size/2) ? n - mesh_size : n;
    weights[threadIdx.x] = n;
  }

  __syncthreads();

  const int n[3] = { weights[blockIdx.x], weights[blockIdx.y], weights[threadIdx.x] };
  const CUFFT_TYPE_COMPLEX meshw = mesh[linear_index];
  CUFFT_TYPE_COMPLEX buf;
  buf.x = -2.0 * PI * meshw.y / box;
  buf.y =  2.0 * PI * meshw.x / box;

  force_mesh_x[linear_index].x =  n[0] * buf.x;
  force_mesh_x[linear_index].y =  n[0] * buf.y;

  force_mesh_y[linear_index].x =  n[1] * buf.x;
  force_mesh_y[linear_index].y =  n[1] * buf.y;

  force_mesh_z[linear_index].x =  n[2] * buf.x;
  force_mesh_z[linear_index].y =  n[2] * buf.y;
}

__device__ inline int wrap_index(const int ind, const int mesh) {
  if(ind < 0)
    return ind + mesh;
  else if(ind >= mesh)
    return ind - mesh;
  else 
    return ind;	   
}

__device__ REAL_TYPE caf(int i, REAL_TYPE x, int cao_value) {
  switch (cao_value) {
  case 1 : return 1.0;
  case 2 : {
    switch (i) {
    case 0: return 0.5-x;
    case 1: return 0.5+x;
    default:
      return 0.0;
    }
  } 
  case 3 : { 
    switch (i) {
    case 0: return 0.5*SQR(0.5 - x);
    case 1: return 0.75 - SQR(x);
    case 2: return 0.5*SQR(0.5 + x);
    default:
      return 0.0;
    }
    case 4 : { 
      switch (i) {
      case 0: return ( 1.0+x*( -6.0+x*( 12.0-x* 8.0)))/48.0;
      case 1: return (23.0+x*(-30.0+x*(-12.0+x*24.0)))/48.0;
      case 2: return (23.0+x*( 30.0+x*(-12.0-x*24.0)))/48.0;
      case 3: return ( 1.0+x*(  6.0+x*( 12.0+x* 8.0)))/48.0;
      default:
	return 0.0;
      }
    }
    case 5 : {
      switch (i) {
      case 0: return (  1.0+x*( -8.0+x*(  24.0+x*(-32.0+x*16.0))))/384.0;
      case 1: return ( 19.0+x*(-44.0+x*(  24.0+x*( 16.0-x*16.0))))/ 96.0;
      case 2: return (115.0+x*       x*(-120.0+x*       x*48.0))  /192.0;
      case 3: return ( 19.0+x*( 44.0+x*(  24.0+x*(-16.0-x*16.0))))/ 96.0;
      case 4: return (  1.0+x*(  8.0+x*(  24.0+x*( 32.0+x*16.0))))/384.0;
      default:
	return 0.0;
      }
    }
    case 6 : {
      switch (i) {
      case 0: return (  1.0+x*( -10.0+x*(  40.0+x*( -80.0+x*(  80.0-x* 32.0)))))/3840.0;
      case 1: return (237.0+x*(-750.0+x*( 840.0+x*(-240.0+x*(-240.0+x*160.0)))))/3840.0;
      case 2: return (841.0+x*(-770.0+x*(-440.0+x*( 560.0+x*(  80.0-x*160.0)))))/1920.0;
      case 3: return (841.0+x*(+770.0+x*(-440.0+x*(-560.0+x*(  80.0+x*160.0)))))/1920.0;
      case 4: return (237.0+x*( 750.0+x*( 840.0+x*( 240.0+x*(-240.0-x*160.0)))))/3840.0;
      case 5: return (  1.0+x*(  10.0+x*(  40.0+x*(  80.0+x*(  80.0+x* 32.0)))))/3840.0;
      default:
	return 0.0;
      }
    }
    case 7 : {
      switch (i) {
      case 0: return (    1.0+x*(   -12.0+x*(   60.0+x*( -160.0+x*(  240.0+x*(-192.0+x* 64.0))))))/46080.0;
      case 1: return (  361.0+x*( -1416.0+x*( 2220.0+x*(-1600.0+x*(  240.0+x*( 384.0-x*192.0))))))/23040.0;
      case 2: return (10543.0+x*(-17340.0+x*( 4740.0+x*( 6880.0+x*(-4080.0+x*(-960.0+x*960.0))))))/46080.0;
      case 3: return ( 5887.0+x*          x*(-4620.0+x*         x*( 1680.0-x*        x*320.0)))   /11520.0;
      case 4: return (10543.0+x*( 17340.0+x*( 4740.0+x*(-6880.0+x*(-4080.0+x*( 960.0+x*960.0))))))/46080.0;
      case 5: return (  361.0+x*(  1416.0+x*( 2220.0+x*( 1600.0+x*(  240.0+x*(-384.0-x*192.0))))))/23040.0;
      case 6: return (    1.0+x*(    12.0+x*(   60.0+x*(  160.0+x*(  240.0+x*( 192.0+x* 64.0))))))/46080.0;
      default:
	return 0.0;
      }
    }
  }}
  return 0.0;
}

__global__ void apply_influence_function( CUFFT_TYPE_COMPLEX *mesh, int mesh_size, REAL_TYPE *G_hat ) {
  int linear_index = mesh_size*mesh_size*blockIdx.x + mesh_size * blockIdx.y + threadIdx.x;
  mesh[linear_index].x *= G_hat[linear_index];
  mesh[linear_index].y *= G_hat[linear_index];
}


template<int cao>
__global__ void assign_charge_kernel_shared(const CUDA_particle_data * const pdata,
				     CUFFT_TYPE_COMPLEX *mesh, const int m_size, const REAL_TYPE pos_shift, const
				     REAL_TYPE hi, int n_part, int parts_per_block) {
  const int part_in_block = threadIdx.x / cao;
  const int cao_id_x = threadIdx.x % cao;
  /** id of the particle **/
  int id = parts_per_block * (blockIdx.x*gridDim.y + blockIdx.y) + part_in_block;
  if(id >= n_part)
    return;
  /** position relative to the closest gird point **/
  REAL_TYPE m_pos[3];
  /** index of the nearest mesh point **/
  int nmp_x, nmp_y, nmp_z;      
      
  const CUDA_particle_data p = pdata[id];

  m_pos[0] = p.p[0] * hi - pos_shift;
  m_pos[1] = p.p[1] * hi - pos_shift;
  m_pos[2] = p.p[2] * hi - pos_shift;

  nmp_x = (int) floor(m_pos[0] + 0.5);
  nmp_y = (int) floor(m_pos[1] + 0.5);
  nmp_z = (int) floor(m_pos[2] + 0.5);

  m_pos[0] -= nmp_x;
  m_pos[1] -= nmp_y;
  m_pos[2] -= nmp_z;

  nmp_x = wrap_index(nmp_x +    cao_id_x, m_size);
  nmp_y = wrap_index(nmp_y + threadIdx.y, m_size);
  nmp_z = wrap_index(nmp_z + threadIdx.z, m_size);

  if((threadIdx.y < 3) && (threadIdx.z == 0)) {
    weights[3*cao*part_in_block + 3*cao_id_x + threadIdx.y] = caf<cao>(cao_id_x, m_pos[threadIdx.y]);
  }

   __syncthreads();

  atomicAdd( &(mesh[m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z].x), weights[3*cao*part_in_block + 3*cao_id_x + 0]*weights[3*cao*part_in_block + 3*threadIdx.y + 1]*weights[3*cao*part_in_block + 3*threadIdx.z + 2]*p.q);
}

template<int cao>
__global__ void assign_charge_kernel(const CUDA_particle_data * const pdata,
				     CUFFT_TYPE_COMPLEX *mesh, const int m_size, const REAL_TYPE pos_shift, const
				     REAL_TYPE hi, int n_part, int parts_per_block) {  
  const int part_in_block = threadIdx.x / cao;
  const int cao_id_x = threadIdx.x % cao;
  /** id of the particle **/
  const int id = parts_per_block * (blockIdx.x + blockDim.x*blockIdx.y) + part_in_block;
  // printf("block %d %d, thread %d %d %d, id %d, p_i_b %d cao_id_x %d\n",
  // 	 blockIdx.x, blockIdx.y, threadIdx.x, threadIdx.y, threadIdx.z,
  // 	 id, part_in_block, cao_id_x);
  if(id >= n_part)
    return;
  /** position relative to the closest gird point **/
  REAL_TYPE m_pos[3];
  /** index of the nearest mesh point **/
  int nmp_x, nmp_y, nmp_z;      
      
  const CUDA_particle_data p = pdata[id];

  m_pos[0] = p.p[0] * hi - pos_shift;
  m_pos[1] = p.p[1] * hi - pos_shift;
  m_pos[2] = p.p[2] * hi - pos_shift;

  nmp_x = (int) floor(m_pos[0] + 0.5);
  nmp_y = (int) floor(m_pos[1] + 0.5);
  nmp_z = (int) floor(m_pos[2] + 0.5);

  m_pos[0] -= nmp_x;
  m_pos[1] -= nmp_y;
  m_pos[2] -= nmp_z;

  nmp_x = wrap_index(nmp_x +    cao_id_x, m_size);
  nmp_y = wrap_index(nmp_y + threadIdx.y, m_size);
  nmp_z = wrap_index(nmp_z + threadIdx.z, m_size);

  atomicAdd( &(mesh[m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z].x), caf<cao>(cao_id_x, m_pos[0])*caf<cao>(threadIdx.y, m_pos[1])*caf<cao>(threadIdx.z, m_pos[2])*p.q);
}

template<>
__global__ void assign_charge_kernel<1>(const CUDA_particle_data * const pdata,
				     CUFFT_TYPE_COMPLEX *mesh, const int m_size, const REAL_TYPE pos_shift, const
				     REAL_TYPE hi, int n_part, int parts_per_block) {
  /** id of the particle **/
  int id = parts_per_block * (blockIdx.x*gridDim.y + blockIdx.y) + threadIdx.x;
  if(id >= n_part)
    return;
  /** position relative to the closest gird point **/
  REAL_TYPE m_pos[3];
  /** index of the nearest mesh point **/
  int nmp_x, nmp_y, nmp_z;      
      
  const CUDA_particle_data p = pdata[id];

  m_pos[0] = p.p[0] * hi - pos_shift;
  m_pos[1] = p.p[1] * hi - pos_shift;
  m_pos[2] = p.p[2] * hi - pos_shift;

  nmp_x = (int) floor(m_pos[0] + 0.5);
  nmp_y = (int) floor(m_pos[1] + 0.5);
  nmp_z = (int) floor(m_pos[2] + 0.5);

  m_pos[0] -= nmp_x;
  m_pos[1] -= nmp_y;
  m_pos[2] -= nmp_z;

  nmp_x = wrap_index(nmp_x, m_size);
  nmp_y = wrap_index(nmp_y, m_size);
  nmp_z = wrap_index(nmp_z, m_size);

  atomicAdd( &(mesh[m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z].x), p.q);
}


void assign_charges(int n_part, const CUDA_particle_data * const pdata, CUFFT_TYPE_COMPLEX *mesh, const int m_size, const REAL_TYPE pos_shift, const
		    REAL_TYPE hi, int cao) {
  dim3 grid, block;
  grid.z = 1;
  const int cao3 = cao*cao*cao;
  int parts_per_block = 1, n_blocks = 1;

  while((parts_per_block+1)*cao3 <= THREADS_PER_BLOCK) {
    parts_per_block++;
  }
  if((n_part % parts_per_block) == 0)
    n_blocks = max(1, n_part / parts_per_block);
  else
    n_blocks = n_part / parts_per_block + 1;

  grid.x = n_blocks;
  grid.y = 1;
  while(grid.x > 65536) {
    grid.y++;
    if((n_blocks % grid.y) == 0)
      grid.x = max(1, n_blocks / grid.y);
    else
      grid.x = n_blocks / grid.y + 1;
  }

  block.x = parts_per_block * cao;
  block.y = cao;
  block.z = cao;

  // printf("n_part %d, parts_per_block %d, n_blocks %d\n", n_part, parts_per_block, n_blocks);
  // printf("grid %d %d %d block %d %d %d\n", grid.x, grid.y, grid.z, block.x, block.y, block.z);

  switch(cao) {
  case 1:
    assign_charge_kernel<1><<<grid, block>>>(pdata, mesh, m_size, pos_shift, hi, n_part, parts_per_block);
    break;
  case 2:
    assign_charge_kernel<2><<<grid, block>>>(pdata, mesh, m_size, pos_shift, hi, n_part, parts_per_block);
    break;
  case 3:
    assign_charge_kernel_shared<3><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh, m_size, pos_shift, hi, n_part, parts_per_block);
    break;
  case 4:
    assign_charge_kernel_shared<4><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh, m_size, pos_shift, hi, n_part, parts_per_block);
    break;
  case 5:
    assign_charge_kernel_shared<5><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh, m_size, pos_shift, hi, n_part, parts_per_block);
    break;
  case 6:
    assign_charge_kernel_shared<6><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh, m_size, pos_shift, hi, n_part, parts_per_block);
    break;
  case 7:
    assign_charge_kernel_shared<7><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh, m_size, pos_shift, hi, n_part, parts_per_block);
    break;
  default:
    break;
  }
  _cuda_check_errors(block, grid, "assign_charge", __FILE__, __LINE__);
}

template<int cao>
__global__ void assign_forces_kernel(const CUDA_particle_data * const pdata, CUFFT_TYPE_COMPLEX *mesh_x, CUFFT_TYPE_COMPLEX *mesh_y, CUFFT_TYPE_COMPLEX *mesh_z, const int m_size, const REAL_TYPE pos_shift, const
				     REAL_TYPE hi, CUDA_particle_force * lb_particle_force_gpu, REAL_TYPE prefactor,int n_part, int parts_per_block) {
  const int part_in_block = threadIdx.x / cao;
  const int cao_id_x = threadIdx.x % cao;
  /** id of the particle **/
  int id = parts_per_block * (blockIdx.x*gridDim.y + blockIdx.y) + part_in_block;
  if(id >= n_part)
    return;
  /** position relative to the closest gird point **/
  REAL_TYPE m_pos[3];
  /** index of the nearest mesh point **/
  int nmp_x, nmp_y, nmp_z;      

  const CUDA_particle_data p = pdata[id];

  m_pos[0] = p.p[0] * hi - pos_shift;
  m_pos[1] = p.p[1] * hi - pos_shift;
  m_pos[2] = p.p[2] * hi - pos_shift;

  nmp_x = (int) floor(m_pos[0] + 0.5);
  nmp_y = (int) floor(m_pos[1] + 0.5);
  nmp_z = (int) floor(m_pos[2] + 0.5);

  m_pos[0] -= nmp_x;
  m_pos[1] -= nmp_y;
  m_pos[2] -= nmp_z;

  nmp_x = wrap_index(nmp_x + cao_id_x, m_size);
  nmp_y = wrap_index(nmp_y + threadIdx.y, m_size);
  nmp_z = wrap_index(nmp_z + threadIdx.z, m_size);

  const int index = m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z;
  const float c = -prefactor*caf<cao>(cao_id_x, m_pos[0])*caf<cao>(threadIdx.y, m_pos[1])*caf<cao>(threadIdx.z, m_pos[2])*p.q;

  atomicAdd( &(lb_particle_force_gpu[id].f[0]), c*mesh_x[index].x);      
  atomicAdd( &(lb_particle_force_gpu[id].f[1]), c*mesh_y[index].x);      
  atomicAdd( &(lb_particle_force_gpu[id].f[2]), c*mesh_z[index].x);      
}

template<int cao>
__global__ void assign_forces_kernel_shared(const CUDA_particle_data * const pdata, CUFFT_TYPE_COMPLEX *mesh_x, CUFFT_TYPE_COMPLEX *mesh_y, CUFFT_TYPE_COMPLEX *mesh_z, const int m_size, const REAL_TYPE pos_shift, const
				     REAL_TYPE hi, CUDA_particle_force * lb_particle_force_gpu, REAL_TYPE prefactor, int n_part, int parts_per_block) {
  const int part_in_block = threadIdx.x / cao;
  const int cao_id_x = threadIdx.x % cao;
  /** id of the particle **/
  int id = parts_per_block * (blockIdx.x*gridDim.y + blockIdx.y) + part_in_block;
  if(id >= n_part)
    return;
  /** position relative to the closest gird point **/
  REAL_TYPE m_pos[3];
  /** index of the nearest mesh point **/
  int nmp_x, nmp_y, nmp_z;      

  const CUDA_particle_data p = pdata[id];

  m_pos[0] = p.p[0] * hi - pos_shift;
  m_pos[1] = p.p[1] * hi - pos_shift;
  m_pos[2] = p.p[2] * hi - pos_shift;

  nmp_x = (int) floor(m_pos[0] + 0.5);
  nmp_y = (int) floor(m_pos[1] + 0.5);
  nmp_z = (int) floor(m_pos[2] + 0.5);

  m_pos[0] -= nmp_x;
  m_pos[1] -= nmp_y;
  m_pos[2] -= nmp_z;

  nmp_x = wrap_index(nmp_x + cao_id_x, m_size);
  nmp_y = wrap_index(nmp_y + threadIdx.y, m_size);
  nmp_z = wrap_index(nmp_z + threadIdx.z, m_size);

  if((threadIdx.y < 3) && (threadIdx.z == 0)) {
    weights[3*cao*part_in_block + 3*cao_id_x + threadIdx.y] = caf<cao>(cao_id_x, m_pos[threadIdx.y]);
  }

  __syncthreads();

  const int index = m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z;
  const float c = -prefactor*weights[3*cao*part_in_block + 3*cao_id_x + 0]*weights[3*cao*part_in_block + 3*threadIdx.y + 1]*weights[3*cao*part_in_block + 3*threadIdx.z + 2]*p.q;
 
  atomicAdd( &(lb_particle_force_gpu[id].f[0]), c*mesh_x[index].x);      
  atomicAdd( &(lb_particle_force_gpu[id].f[1]), c*mesh_y[index].x);      
  atomicAdd( &(lb_particle_force_gpu[id].f[2]), c*mesh_z[index].x);      

}


// template<>
// __global__ void assign_forces_kernel<1>(const CUDA_particle_data * const pdata, CUFFT_TYPE_COMPLEX *mesh, const int m_size, const REAL_TYPE pos_shift, const
// 					REAL_TYPE hi, CUDA_particle_force * lb_particle_force_gpu, REAL_TYPE prefactor, int dim, int n_part, int parts_per_block) {
//   /** id of the particle **/
//   int id = parts_per_block * (blockIdx.x*gridDim.y + blockIdx.y) + threadIdx.x;
//   if(id >= n_part)
//     return;
//   /** position relative to the closest gird point **/
//   REAL_TYPE m_pos[3];
//   /** index of the nearest mesh point **/
//   int nmp_x, nmp_y, nmp_z;      

//   const CUDA_particle_data p = pdata[id];

//   m_pos[0] = p.p[0] * hi - pos_shift;
//   m_pos[1] = p.p[1] * hi - pos_shift;
//   m_pos[2] = p.p[2] * hi - pos_shift;

//   nmp_x = (int) floor(m_pos[0] + 0.5);
//   nmp_y = (int) floor(m_pos[1] + 0.5);
//   nmp_z = (int) floor(m_pos[2] + 0.5);

//   m_pos[0] -= nmp_x;
//   m_pos[1] -= nmp_y;
//   m_pos[2] -= nmp_z;

//   nmp_x = wrap_index(nmp_x, m_size);
//   nmp_y = wrap_index(nmp_y, m_size);
//   nmp_z = wrap_index(nmp_z, m_size);

//   const int index = m_size*m_size*nmp_x +  m_size*nmp_y + nmp_z;
//   const float c = -prefactor*p.q; 

//   atomicAdd( &(lb_particle_force_gpu[id].f[0]), c*mesh_x[index].x);      
//   atomicAdd( &(lb_particle_force_gpu[id].f[1]), c*mesh_y[index].x);      
//   atomicAdd( &(lb_particle_force_gpu[id].f[2]), c*mesh_z[index].x);      

// }

void assign_forces(int n_part, const CUDA_particle_data * const pdata, 
		   CUFFT_TYPE_COMPLEX *mesh_x, CUFFT_TYPE_COMPLEX *mesh_y, CUFFT_TYPE_COMPLEX *mesh_z, const int m_size, 
		   const REAL_TYPE pos_shift, const REAL_TYPE hi, CUDA_particle_force * lb_particle_force_gpu, REAL_TYPE prefactor, int cao) {
  dim3 grid, block;
  grid.z = 1;

  const int cao3 = cao*cao*cao;
  int parts_per_block = 1, n_blocks = 1;

  while((parts_per_block+1)*cao3 <= 1024) {
    parts_per_block++;
  }
  if((n_part % parts_per_block) == 0)
    n_blocks = max(1, n_part / parts_per_block);
  else
    n_blocks = n_part / parts_per_block + 1;

    grid.x = n_blocks;
    grid.y = 1;
    while(grid.x > 65536) {
      grid.y++;
      if((n_blocks % grid.y) == 0)
	grid.x = max(1, n_blocks / grid.y);
      else
	grid.x = n_blocks / grid.y + 1;
    }

    block.x = parts_per_block * cao;
    block.y = cao;
    block.z = cao;

    // printf("cao %d, parts_per_block %d n_blocks %d\n", cao, parts_per_block, n_blocks);
    // printf("grid %d %d %d, block %d %d %d\n", grid.x, grid.y, grid.z, block.x, block.y, block.z);
    // printf("total threads = %d, ca points = %d\n", grid.x*grid.y*grid.z*block.x*block.y*block.z, cao3*n_part);

  switch(cao) {
  case 1:
    assign_forces_kernel<1><<<grid, block>>>(pdata, mesh_x, mesh_y, mesh_z, m_size, pos_shift, hi, lb_particle_force_gpu, prefactor, n_part, parts_per_block);
    break;
  case 2:
    assign_forces_kernel<2><<<grid, block>>>(pdata, mesh_x, mesh_y, mesh_z, m_size, pos_shift, hi, lb_particle_force_gpu, prefactor, n_part, parts_per_block);
    break;
  case 3:
    assign_forces_kernel_shared<3><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh_x, mesh_y, mesh_z, m_size, pos_shift, hi, lb_particle_force_gpu, prefactor, n_part, parts_per_block);
    break;
  case 4:
    assign_forces_kernel_shared<4><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh_x, mesh_y, mesh_z, m_size, pos_shift, hi, lb_particle_force_gpu, prefactor, n_part, parts_per_block);
    break;
  case 5:
    assign_forces_kernel_shared<5><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh_x, mesh_y, mesh_z, m_size, pos_shift, hi, lb_particle_force_gpu, prefactor, n_part, parts_per_block);
    break;
  case 6:
    assign_forces_kernel_shared<6><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh_x, mesh_y, mesh_z, m_size, pos_shift, hi, lb_particle_force_gpu, prefactor, n_part, parts_per_block);
    break;
  case 7:
    assign_forces_kernel_shared<7><<<grid, block, 3*parts_per_block*cao*sizeof(float)>>>(pdata, mesh_x, mesh_y, mesh_z, m_size, pos_shift, hi, lb_particle_force_gpu, prefactor, n_part, parts_per_block);
    break;
  default:
    break;
  }
  _cuda_check_errors(block, grid, "assign_forces", __FILE__, __LINE__);
}


extern "C" {

  /* Init the internal datastructures of the P3M GPU.
   * Mainly allocation on the device and influence function calculation.
   * Be advised: this needs mesh^3*5*sizeof(REAL_TYPE) of device memory. 
   */

  void p3m_gpu_init(int cao, int mesh, REAL_TYPE alpha, REAL_TYPE box) {
    int reinit_if = 0, mesh_changed = 0;
 
    espressoSystemInterface.requestParticleStructGpu();

    if ( this_node == 0 ) {
      

      p3m_gpu_data.npart = gpu_get_global_particle_vars_pointer_host()->number_of_particles;
      
      if((p3m_gpu_data_initialized == 0) || (p3m_gpu_data.alpha != alpha)) {
	p3m_gpu_data.alpha = alpha;
	reinit_if = 1;
      }

      if((p3m_gpu_data_initialized == 0) || (p3m_gpu_data.cao != cao)) {
	p3m_gpu_data.cao = cao;
	reinit_if = 1;
      }
	
      if((p3m_gpu_data_initialized == 0) || (p3m_gpu_data.mesh != mesh)) {
	p3m_gpu_data.mesh = mesh;
	mesh_changed = 1;
	reinit_if = 1;
      }

      if((p3m_gpu_data_initialized == 0) || (p3m_gpu_data.box != box)) {
	p3m_gpu_data.box = box;
	reinit_if = 1;
      }
     
      int mesh3 = mesh*mesh*mesh;

      if((p3m_gpu_data_initialized == 1) && (mesh_changed == 1)) {
	cudaFree(p3m_gpu_data.charge_mesh);
	cudaFree(p3m_gpu_data.force_mesh_x);
	cudaFree(p3m_gpu_data.force_mesh_y);
	cudaFree(p3m_gpu_data.force_mesh_z);
	cudaFree(p3m_gpu_data.G_hat);

	free(p3m_gpu_data.G_hat_host);

	cufftDestroy(p3m_gpu_data.fft_plan);

	p3m_gpu_data_initialized = 0;
      }

      if(p3m_gpu_data_initialized == 0 && mesh > 0) {
	cudaMalloc((void **)&(p3m_gpu_data.charge_mesh), mesh3*sizeof(CUFFT_TYPE_COMPLEX));
	cudaMalloc((void **)&(p3m_gpu_data.force_mesh_x), mesh3*sizeof(CUFFT_TYPE_COMPLEX));
	cudaMalloc((void **)&(p3m_gpu_data.force_mesh_y), mesh3*sizeof(CUFFT_TYPE_COMPLEX));
	cudaMalloc((void **)&(p3m_gpu_data.force_mesh_z), mesh3*sizeof(CUFFT_TYPE_COMPLEX));
	cudaMalloc((void **)&(p3m_gpu_data.G_hat), mesh3*sizeof(REAL_TYPE));

	p3m_gpu_data.G_hat_host = (REAL_TYPE *)malloc(mesh3*sizeof(REAL_TYPE));

	cufftPlan3d(&(p3m_gpu_data.fft_plan), mesh, mesh, mesh, CUFFT_PLAN_FLAG);
      }

      if(((reinit_if == 1) || (p3m_gpu_data_initialized == 0)) && mesh > 0) {
	// // Calculate influence function of host.
	calculate_influence_function( cao, mesh, box, alpha, p3m_gpu_data.G_hat_host);

	// // Copy influence function to device.
	cudaMemcpy( p3m_gpu_data.G_hat, p3m_gpu_data.G_hat_host, mesh3*sizeof(REAL_TYPE), cudaMemcpyHostToDevice);
	dim3 grid(1,1,1);
	dim3 block(1,1,1);
        block.y = mesh;
	block.z = 1;
	block.x = 512 / mesh + 1;
	grid.x = mesh / block.x + 1;
	grid.z = mesh;

	//	printf("mesh %d, grid (%d %d %d), block (%d %d %d)\n", mesh, grid.x, grid.y, grid.z, block.x, block.y, block.z);

	//	KERNELCALL(calculate_influence_function_device,grid,block,(cao, mesh, box, alpha, p3m_gpu_data.G_hat));
	cudaThreadSynchronize();
      }
      p3m_gpu_data_initialized = 1;
    }
  }

  void p3m_gpu_add_farfield_force() {

    CUDA_particle_data* lb_particle_gpu;
    CUDA_particle_force* lb_particle_force_gpu;
  
    int mesh = p3m_gpu_data.mesh;
    int mesh3 = mesh*mesh*mesh;
    int cao = p3m_gpu_data.cao;
    REAL_TYPE box = p3m_gpu_data.box;

    lb_particle_gpu = gpu_get_particle_pointer();
    lb_particle_force_gpu = gpu_get_particle_force_pointer();

    p3m_gpu_data.npart = gpu_get_global_particle_vars_pointer_host()->number_of_particles;

    if(p3m_gpu_data.npart == 0)
      return;

    dim3 gridAssignment(p3m_gpu_data.npart,1,1);
    dim3 threadsAssignment(cao,cao,cao);
  
    dim3 gridConv(mesh,mesh,1);
    dim3 threadsConv(mesh,1,1);

    REAL_TYPE pos_shift = (REAL_TYPE)((cao-1)/2);
    REAL_TYPE hi = mesh/box;
    REAL_TYPE prefactor = 1.0/(box*box*box*2.0);

    cuda_safe_mem(cudaMemset( p3m_gpu_data.charge_mesh, 0, mesh3*sizeof(CUFFT_TYPE_COMPLEX)));

    assign_charges(p3m_gpu_data.npart, lb_particle_gpu, p3m_gpu_data.charge_mesh, mesh, pos_shift, hi, cao);

    if (CUFFT_FFT(p3m_gpu_data.fft_plan, p3m_gpu_data.charge_mesh, p3m_gpu_data.charge_mesh, CUFFT_FORWARD) != CUFFT_SUCCESS){
      fprintf(stderr, "CUFFT error: ExecZ2Z Forward failed\n");
      return;
    }

    KERNELCALL( apply_influence_function, gridConv, threadsConv, (p3m_gpu_data.charge_mesh, mesh, p3m_gpu_data.G_hat));

    dim3 gridAssignment2(1,1,1);
    dim3 threadsAssignment2(1,1,1);
    if(p3m_gpu_data.npart <= 512) {
      threadsAssignment2.x = p3m_gpu_data.npart;
    } else {
      threadsAssignment2.x = 512;
      if((p3m_gpu_data.npart % 512) == 0) {
	gridAssignment2.x = p3m_gpu_data.npart / 512;
      }
      else {
	gridAssignment2.x = p3m_gpu_data.npart / 512 + 1;
      }
    }

    KERNELCALL_shared(apply_diff_op, gridConv, threadsConv, mesh*sizeof(REAL_TYPE), (p3m_gpu_data.charge_mesh, mesh, 
    										     p3m_gpu_data.force_mesh_x, p3m_gpu_data.force_mesh_y, p3m_gpu_data.force_mesh_z, box));
  
    CUFFT_FFT(p3m_gpu_data.fft_plan, p3m_gpu_data.force_mesh_x, p3m_gpu_data.force_mesh_x, CUFFT_INVERSE);
    CUFFT_FFT(p3m_gpu_data.fft_plan, p3m_gpu_data.force_mesh_y, p3m_gpu_data.force_mesh_y, CUFFT_INVERSE);
    CUFFT_FFT(p3m_gpu_data.fft_plan, p3m_gpu_data.force_mesh_z, p3m_gpu_data.force_mesh_z, CUFFT_INVERSE);

// void assign_forces(int n_part, const CUDA_particle_data * const pdata, 
// 		   CUFFT_TYPE_COMPLEX *mesh_x, CUFFT_TYPE_COMPLEX *mesh_y, CUFFT_TYPE_COMPLEX *mesh_z, const int m_size, 
// 		   const REAL_TYPE pos_shift, const REAL_TYPE hi, CUDA_particle_force * lb_particle_force_gpu, REAL_TYPE prefactor, int dim, int cao) {
    assign_forces(p3m_gpu_data.npart, lb_particle_gpu, p3m_gpu_data.force_mesh_x, p3m_gpu_data.force_mesh_y, p3m_gpu_data.force_mesh_z,
		  mesh, pos_shift, hi, lb_particle_force_gpu, prefactor, cao);
  }

}

#endif /* ELECTROSTATICS */
