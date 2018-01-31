////////////////////////////////////////////////////////////////////////////////
// Shaders to reproject radiance from last frame
////////////////////////////////////////////////////////////////////////////////
//
#include "Global.hlsl"

#define THREADS_X	16
#define THREADS_Y	16

Texture2D< float4 >		_tex_sourceRadiance : register(t0);
Texture2D< float >		_tex_depth : register(t1);			// Depth or distance buffer (here we're given depth)
Texture2D< float3 >		_tex_motionVectors : register(t2);	// Motion vectors in camera space

Texture2D< float4 >		_tex_sourceRadianceCurrentMip : register(t3);
RWTexture2D< float4 >	_tex_reprojectedRadiance : register(u0);

cbuffer CB_PushPull : register( b3 ) {
	uint2	_targetSize;
};

////////////////////////////////////////////////////////////////////////////////
// Reprojects last frame's radiance
[numthreads( THREADS_X, THREADS_Y, 1 )]
void	CS_Reproject( uint3 _groupID : SV_groupID, uint3 _groupThreadID : SV_groupThreadID, uint3 _dispatchThreadID : SV_dispatchThreadID ) {
	uint2	pixelPosition = _dispatchThreadID.xy;
	float2	UV = float2( pixelPosition + 0.5 ) / _resolution;

	// Compute previous camera-space position
	float	previousZ = Z_FAR * _tex_depth[pixelPosition];
	float3	csView = BuildCameraRay( UV );
//	float	Z2Distance = length( csView );
	float3	csPreviousPosition = csView * previousZ;
			csPreviousPosition += _deltaTime * _tex_motionVectors[pixelPosition];	// Extrapolate new position using last frame's camera-space velocity

	// Re-project
	float3	csNewPosition = mul( float4( csPreviousPosition, 1.0 ), _PrevioucCamera2CurrentCamera ).xyz;
	float	newZ = csNewPosition.z;
			csNewPosition.xy /= csNewPosition.z;
	float2	newUV = 0.5 * (1.0 + float2( csNewPosition.x / (TAN_HALF_FOV * _resolution.x / _resolution.y), csNewPosition.y / -TAN_HALF_FOV ));
	int2	newPixelPosition = floor( newUV * _resolution );

//newPixelPosition = pixelPosition;

	if ( any( newPixelPosition < 0 ) || any( newPixelPosition >= _resolution ) )
		return;	// Off screen..

	float3	previousRadiance = _tex_sourceRadiance[pixelPosition].xyz;

//previousRadiance = float3( UV, 0 );
//previousRadiance = float3( newUV, 0 );
//previousRadiance = float3( 1, 0, 1 );

	_tex_reprojectedRadiance[newPixelPosition] = float4( previousRadiance, newZ );	// Store depth in alpha (will be used for bilateral filtering later)
}

////////////////////////////////////////////////////////////////////////////////
// Implements the PUSH phase of the push/pull algorithm described in "The Pull-Push Algorithm Revisited" M. Kraus (2009)
// https://pdfs.semanticscholar.org/9efe/2c33d8db1609276b989f569b66f1a90feaca.pdf
//
// Actually, this is called the "pull" phase in the original algorithm but I prefer thinking of it as pushing valid values down to the lower mips...
//
[numthreads( THREADS_X, THREADS_Y, 1 )]
void	CS_Push( uint3 _groupID : SV_groupID, uint3 _groupThreadID : SV_groupThreadID, uint3 _dispatchThreadID : SV_dispatchThreadID ) {
	uint2	targetPixelIndex = _dispatchThreadID.xy;
	if ( any( targetPixelIndex > _targetSize ) )
		return;

	// Fetch the 4 source pixels
	uint2	sourcePixelIndex = targetPixelIndex << 1;
	float4	V00 = _tex_sourceRadiance[sourcePixelIndex];	sourcePixelIndex.x++;
	float4	V10 = _tex_sourceRadiance[sourcePixelIndex];	sourcePixelIndex.y++;
	float4	V11 = _tex_sourceRadiance[sourcePixelIndex];	sourcePixelIndex.x--;
	float4	V01 = _tex_sourceRadiance[sourcePixelIndex];	sourcePixelIndex.y--;
    
	// Pre-multiply by alpha
	float3	C = V00.w * V00.xyz;
			  + V10.w * V10.xyz;
			  + V01.w * V01.xyz;
			  + V11.w * V11.xyz;

	float	sumWeights = V00.w + V10.w + V01.w + V11.w;
	float	A = saturate( sumWeights );
	float	normalization = sumWeights > 0.0 ? A / sumWeights : 0.0;

	// Store de-premultiplied color
	_tex_reprojectedRadiance[targetPixelIndex] = float4( normalization * C, A );
}


////////////////////////////////////////////////////////////////////////////////
// Implements the PULL phase of the push/pull algorithm described in "The Pull-Push Algorithm Revisited" M. Kraus (2009)
// Actually, this is called the "push" phase in the original algorithm but I prefer thinking of it as pulling valid values up from to the lower mips...
//
[numthreads( THREADS_X, THREADS_Y, 1 )]
void	CS_Pull( uint3 _groupID : SV_groupID, uint3 _groupThreadID : SV_groupThreadID, uint3 _dispatchThreadID : SV_dispatchThreadID ) {
	uint2	targetPixelIndex = _dispatchThreadID.xy;
	if ( any( targetPixelIndex > _targetSize ) )
		return;

	float2	UV = float2(targetPixelIndex) / _targetSize;
	float2	dUV = 1.0 / _targetSize;

	// Read currently existing value (possibly already valid)
	float4	oldV = _tex_sourceRadianceCurrentMip[targetPixelIndex];
//	float4	oldV = UV.xyxy;//_tex_reprojectedRadiance.SampleLevel( LinearClamp, UV + 0.5 * dUV, 0.0 );
//	oldV.w = 0.0;

	// Bilinear interpolate the 4 surrounding, lower mip pixels
	float4	V00 = _tex_sourceRadiance.SampleLevel( LinearClamp, UV, 0.0 );	UV.x += dUV.x;
	float4	V10 = _tex_sourceRadiance.SampleLevel( LinearClamp, UV, 0.0 );	UV.y += dUV.y;
	float4	V11 = _tex_sourceRadiance.SampleLevel( LinearClamp, UV, 0.0 );	UV.x -= dUV.x;
	float4	V01 = _tex_sourceRadiance.SampleLevel( LinearClamp, UV, 0.0 );	UV.y -= dUV.y;
    
	// Pre-multiply by alpha
	float3	C = V00.w * V00.xyz;
			  + V10.w * V10.xyz;
			  + V01.w * V01.xyz;
			  + V11.w * V11.xyz;

	float	sumWeights = V00.w + V10.w + V01.w + V11.w;
	float	A = saturate( sumWeights );
	float	normalization = sumWeights > 0.0 ? A / sumWeights : 0.0;

	float4	newV = float4( normalization * C, A );	// De-premultiply color

	// Store the color with the most significance (i.e. best weight)
	_tex_reprojectedRadiance[targetPixelIndex] = lerp( newV, oldV, saturate( oldV.w ) );
}
