//
//  Shaders.metal
//

// File for Metal kernel and shader functions

#include <metal_stdlib>
#include <simd/simd.h>

// Including header shared between this Metal shader code and Swift/C code executing Metal API commands
#import "ShaderTypes.h"

using namespace metal;

typedef struct
{
    float3 position [[attribute(VertexAttributePosition)]];
    float2 texCoord [[attribute(VertexAttributeTexcoord)]];
} Vertex;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
} ColorInOut;

vertex ColorInOut vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[amp_id];
    
    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    out.texCoord = in.texCoord;

    return out;
}

fragment float4 fragmentShader(ColorInOut in [[stage_in]],
                               texture2d<half> colorMap     [[ texture(TextureIndexColor) ]])
{
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);

    half4 colorSample   = colorMap.sample(colorSampler, in.texCoord.xy);

    return float4(colorSample);
}

// from ALVR

// FFR_COMMON_SHADER_FORMAT

constant uint2 TARGET_RESOLUTION [[ function_constant(ALVRFunctionConstantFfrCommonShaderTargetResolution) ]];
constant uint2 OPTIMIZED_RESOLUTION [[ function_constant(ALVRFunctionConstantFfrCommonShaderOptimizedResolution) ]];
constant float2 EYE_SIZE_RATIO [[ function_constant(ALVRFunctionConstantFfrCommonShaderEyeSizeRatio) ]];
constant float2 CENTER_SIZE [[ function_constant(ALVRFunctionConstantFfrCommonShaderCenterSize) ]];
constant float2 CENTER_SHIFT [[ function_constant(ALVRFunctionConstantFfrCommonShaderCenterShift) ]];
constant float2 EDGE_RATIO [[ function_constant(ALVRFunctionConstantFfrCommonShaderEdgeRatio) ]];

float2 TextureToEyeUV(float2 textureUV, bool isRightEye) {
    // flip distortion horizontally for right eye
    // left: x * 2; right: (1 - x) * 2
    return float2((textureUV.x + float(isRightEye) * (1. - 2. * textureUV.x)) * 2., textureUV.y);
}

float2 EyeToTextureUV(float2 eyeUV, bool isRightEye) {
    // left: x / 2; right 1 - (x / 2)
    return float2(eyeUV.x * 0.5 + float(isRightEye) * (1. - eyeUV.x), eyeUV.y);
}

// DECOMPRESS_AXIS_ALIGNED_FRAGMENT_SHADER
fragment float4 decompressAxisAlignedFragmentShader(ColorInOut in [[stage_in]], texture2d<half> colorMap [[ texture(TextureIndexColor) ]]) {
    float2 uv = in.texCoord;
    bool isRightEye = uv.x > 0.5;
    float2 eyeUV = TextureToEyeUV(uv, isRightEye);

    float2 c0 = (1. - CENTER_SIZE) * 0.5;
    float2 c1 = (EDGE_RATIO - 1.) * c0 * (CENTER_SHIFT + 1.) / EDGE_RATIO;
    float2 c2 = (EDGE_RATIO - 1.) * CENTER_SIZE + 1.;

    float2 loBound = c0 * (CENTER_SHIFT + 1.);
    float2 hiBound = c0 * (CENTER_SHIFT - 1.) + 1.;
    float2 underBound = float2(eyeUV.x < loBound.x, eyeUV.y < loBound.y);
    float2 inBound = float2(loBound.x < eyeUV.x && eyeUV.x < hiBound.x,
                        loBound.y < eyeUV.y && eyeUV.y < hiBound.y);
    float2 overBound = float2(eyeUV.x > hiBound.x, eyeUV.y > hiBound.y);

    float2 center = (eyeUV - c1) * EDGE_RATIO / c2;

    float2 loBoundC = c0 * (CENTER_SHIFT + 1.) / c2;
    float2 hiBoundC = c0 * (CENTER_SHIFT - 1.) / c2 + 1.;

    float2 leftEdge = (-(c1 + c2 * loBoundC) / loBoundC +
                    sqrt(((c1 + c2 * loBoundC) / loBoundC) * ((c1 + c2 * loBoundC) / loBoundC) +
                        4. * c2 * (1. - EDGE_RATIO) / (EDGE_RATIO * loBoundC) * eyeUV)) /
                    (2. * c2 * (1. - EDGE_RATIO)) * (EDGE_RATIO * loBoundC);
    float2 rightEdge =
        (-(c2 - EDGE_RATIO * c1 - 2. * EDGE_RATIO * c2 + c2 * EDGE_RATIO * (1. - hiBoundC) +
        EDGE_RATIO) /
            (EDGE_RATIO * (1. - hiBoundC)) +
        sqrt(((c2 - EDGE_RATIO * c1 - 2. * EDGE_RATIO * c2 + c2 * EDGE_RATIO * (1. - hiBoundC) +
                EDGE_RATIO) /
            (EDGE_RATIO * (1. - hiBoundC))) *
                ((c2 - EDGE_RATIO * c1 - 2. * EDGE_RATIO * c2 +
                    c2 * EDGE_RATIO * (1. - hiBoundC) + EDGE_RATIO) /
                (EDGE_RATIO * (1. - hiBoundC))) -
            4. * ((c2 * EDGE_RATIO - c2) * (c1 - hiBoundC + hiBoundC * c2) /
                        (EDGE_RATIO * (1. - hiBoundC) * (1. - hiBoundC)) -
                    eyeUV * (c2 * EDGE_RATIO - c2) / (EDGE_RATIO * (1. - hiBoundC))))) /
        (2. * c2 * (EDGE_RATIO - 1.)) * (EDGE_RATIO * (1. - hiBoundC));

    float2 uncompressedUV = underBound * leftEdge + inBound * center + overBound * rightEdge;
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);
    half4 colorSample = colorMap.sample(colorSampler, EyeToTextureUV(uncompressedUV * EYE_SIZE_RATIO, isRightEye));
    return float4(colorSample);
}

// VERTEX_SHADER

vertex ColorInOut videoFrameVertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]])
{
    ColorInOut out;

    Uniforms uniforms = uniformsArray.uniforms[amp_id];
    
    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * position;
    if (amp_id == 0) {
        out.texCoord = in.texCoord;
    } else {
        out.texCoord = float2(in.texCoord.x + 0.5, in.texCoord.y);
    }

    return out;
}

fragment float4 videoFrameFragmentShader(ColorInOut in [[stage_in]], texture2d<float> in_tex_y, texture2d<float> in_tex_uv) {
    constexpr sampler colorSampler(mip_filter::linear,
                                   mag_filter::linear,
                                   min_filter::linear);
// https://developer.apple.com/documentation/arkit/arkit_in_ios/displaying_an_ar_experience_with_metal
    float4 ySample = in_tex_y.sample(colorSampler, in.texCoord.xy);
    float4 uvSample = in_tex_uv.sample(colorSampler, in.texCoord.xy);
    
    const float4x4 ycbcrToRGBTransform = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f)
    );
    
    // TODO(zhuowei): gamma is wrong here
    float4 ycbcr = float4(ySample.r, uvSample.rg, 1.0f);
    
    float3 rgb_uncorrect = (ycbcrToRGBTransform * ycbcr).rgb;
    
    const float DIV12 = 1. / 12.92;
    const float DIV1 = 1. / 1.055;
    const float THRESHOLD = 0.04045;
    const float3 GAMMA = float3(2.4);
        
    float3 condition = float3(rgb_uncorrect.r < THRESHOLD, rgb_uncorrect.g < THRESHOLD, rgb_uncorrect.b < THRESHOLD);
    float3 lowValues = rgb_uncorrect * DIV12;
    float3 highValues = pow((rgb_uncorrect + 0.055) * DIV1, GAMMA);
    float3 color = condition * lowValues + (1.0 - condition) * highValues;
    
    return float4(color.rgb, 1.0);
}
