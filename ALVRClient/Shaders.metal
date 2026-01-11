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
    float3 position [[attribute(VertexAttributePosition)]];
} VertexPosOnly;

typedef struct
{
    float4 position [[position]];
    float4 viewPosition;
    float4 color;
    float2 texCoord;
    float planeDoProximity;
} ColorInOutPlane;

typedef struct
{
    float4 position [[position]];
    float2 texCoord;
} ColorInOut;

vertex ColorInOutPlane vertexShader(Vertex in [[stage_in]],
                               ushort amp_id [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]],
                               constant PlaneUniform & planeUniform [[ buffer(BufferIndexPlaneUniforms) ]])
{
    ColorInOutPlane out;

    Uniforms uniforms = uniformsArray.uniforms[amp_id];
    
    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * planeUniform.planeTransform * position;
    out.viewPosition = uniforms.modelViewMatrix * planeUniform.planeTransform * position;
    out.texCoord = in.texCoord;
    out.color = planeUniform.planeColor;
    out.planeDoProximity = planeUniform.planeDoProximity;

    return out;
}

fragment float4 fragmentShader(ColorInOutPlane in [[stage_in]])
{
    float4 color = in.color;
    if (in.planeDoProximity >= 0.5) {
        float cameraDistance = ((-in.viewPosition.z / in.viewPosition.w));
        float cameraX = (in.viewPosition.x);
        float cameraY = (in.viewPosition.y);
        float distFromCenterOfCamera = clamp((2.0 - sqrt(cameraX*cameraX+cameraY*cameraY)) / 2.0, 0.0, 0.9);
        cameraDistance = clamp((1.5 - sqrt(cameraDistance))/1.5, 0.0, 1.0);
        
        color *= pow(distFromCenterOfCamera * cameraDistance, 2.2);
        color.a = in.color.a;
    }
    
    if (color.a <= 0.0) {
        discard_fragment();
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    return color;
}

vertex ColorInOut hudVertexShader(Vertex in [[stage_in]],
                                  ushort amp_id [[amplification_id]],
                                  constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]],
                                  constant PlaneUniform & planeUniform [[ buffer(BufferIndexPlaneUniforms) ]])
{
    ColorInOut out;
    Uniforms uniforms = uniformsArray.uniforms[amp_id];
    float4 position = float4(in.position, 1.0);
    out.position = uniforms.projectionMatrix * uniforms.modelViewMatrix * planeUniform.planeTransform * position;
    out.texCoord = in.texCoord;
    return out;
}

fragment half4 hudFragmentShader(ColorInOut in [[stage_in]],
                                 texture2d<half> in_tex [[texture(TextureIndexColor)]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return in_tex.sample(s, in.texCoord);
}

// from ALVR

// FFR_COMMON_SHADER_FORMAT

constant bool FFR_ENABLED [[ function_constant(ALVRFunctionConstantFfrEnabled) ]];
constant uint2 TARGET_RESOLUTION [[ function_constant(ALVRFunctionConstantFfrCommonShaderTargetResolution) ]];
constant uint2 OPTIMIZED_RESOLUTION [[ function_constant(ALVRFunctionConstantFfrCommonShaderOptimizedResolution) ]];
constant float2 EYE_SIZE_RATIO [[ function_constant(ALVRFunctionConstantFfrCommonShaderEyeSizeRatio) ]];
constant float2 CENTER_SIZE [[ function_constant(ALVRFunctionConstantFfrCommonShaderCenterSize) ]];
constant float2 CENTER_SHIFT [[ function_constant(ALVRFunctionConstantFfrCommonShaderCenterShift) ]];
constant float2 EDGE_RATIO [[ function_constant(ALVRFunctionConstantFfrCommonShaderEdgeRatio) ]];
constant bool CHROMAKEY_ENABLED [[ function_constant(ALVRFunctionConstantChromaKeyEnabled) ]];
constant float3 CHROMAKEY_COLOR [[ function_constant(ALVRFunctionConstantChromaKeyColor) ]];
constant float2 CHROMAKEY_LERP_DIST_RANGE [[ function_constant(ALVRFunctionConstantChromaKeyLerpDistRange) ]];
constant bool REALITYKIT_ENABLED [[ function_constant(ALVRFunctionConstantRealityKitEnabled) ]];
constant float2 VRR_SCREEN_SIZE [[ function_constant(ALVRFunctionConstantVRRScreenSize) ]];
constant float2 VRR_PHYS_SIZE [[ function_constant(ALVRFunctionConstantVRRPhysSize) ]];
constant float ENCODING_GAMMA [[ function_constant(ALVRFunctionConstantEncodingGamma) ]];
constant float4 ENCODING_YUV_TRANSFORM_0 [[ function_constant(ALVRFunctionConstantEncodingYUVTransform0) ]];
constant float4 ENCODING_YUV_TRANSFORM_1 [[ function_constant(ALVRFunctionConstantEncodingYUVTransform1) ]];
constant float4 ENCODING_YUV_TRANSFORM_2 [[ function_constant(ALVRFunctionConstantEncodingYUVTransform2) ]];
constant float4 ENCODING_YUV_TRANSFORM_3 [[ function_constant(ALVRFunctionConstantEncodingYUVTransform3) ]];

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
float2 decompressAxisAlignedCoord(float2 uv) {
    bool isRightEye = uv.x > 0.5;
    float2 eyeUV = TextureToEyeUV(uv, isRightEye);

    const float2 c0 = (1. - CENTER_SIZE) * 0.5;
    const float2 c1 = (EDGE_RATIO - 1.) * c0 * (CENTER_SHIFT + 1.) / EDGE_RATIO;
    const float2 c2 = (EDGE_RATIO - 1.) * CENTER_SIZE + 1.;

    const float2 loBound = c0 * (CENTER_SHIFT + 1.);
    const float2 hiBound = c0 * (CENTER_SHIFT - 1.) + 1.;
    float2 underBound = float2(eyeUV.x < loBound.x, eyeUV.y < loBound.y);
    float2 inBound = float2(loBound.x < eyeUV.x && eyeUV.x < hiBound.x,
                        loBound.y < eyeUV.y && eyeUV.y < hiBound.y);
    float2 overBound = float2(eyeUV.x > hiBound.x, eyeUV.y > hiBound.y);

    float2 center = (eyeUV - c1) * EDGE_RATIO / c2;

    const float2 loBoundC = c0 * (CENTER_SHIFT + 1.) / c2;
    const float2 hiBoundC = c0 * (CENTER_SHIFT - 1.) / c2 + 1.;

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

    // todo: idk why these clamps are necessary
    float2 uncompressedUV = clamp(underBound * leftEdge, float2(0, 0), float2(1, 1)) + clamp(inBound * center, float2(0, 0), float2(1, 1)) + clamp(overBound * rightEdge, float2(0, 0), float2(1, 1));
    return EyeToTextureUV(uncompressedUV * EYE_SIZE_RATIO, isRightEye);
}

// VERTEX_SHADER

ColorInOut videoFrameVertexShaderCommon(ushort vertexID [[vertex_id]],
                               int which,
                               matrix_float4x4 projectionMatrix,
                               matrix_float4x4 modelViewMatrixFrame,
                               simd_float4 tangents)
{
    ColorInOut out;

    float2 uv = float2(float((vertexID << ushort(1)) & 2u) * 0.5, 1.0 - (float(vertexID & ushort(2)) * 0.5));
    float4 position = float4((uv * float2(2.0, -2.0)) + float2(-1.0, 1.0), -500.0, 1.0);

    if (position.x < 1.0) {
        position.x *= tangents[0] * 500.0;
    }
    else {
        position.x *= tangents[1] * 500.0;
    }
    if (position.y < 1.0) {
        position.y *= tangents[3] * 500.0;
    }
    else {
        position.y *= tangents[2] * 500.0;
    }
    out.position = projectionMatrix * modelViewMatrixFrame * position;
    if (which == 0) {
        out.texCoord = float2((uv.x * 0.5), uv.y);
    } else {
        out.texCoord = float2((uv.x * 0.5) + 0.5,  uv.y);
    }

    return out;
}

vertex ColorInOut videoFrameVertexShader(ushort vertexID [[vertex_id]],
                               ushort amp_id [[amplification_id]],
                               constant UniformsArray & uniformsArray [[ buffer(BufferIndexUniforms) ]])
{
    int which = (vertexID >= 4 ? 1 : 0) + amp_id;
    Uniforms uniforms = uniformsArray.uniforms[which];
    
    return videoFrameVertexShaderCommon(vertexID, which, uniforms.projectionMatrix, uniforms.modelViewMatrixFrame, uniforms.tangents);
}

float3 NonlinearToLinearRGB(float3 color) {
    const float DIV12 = 1. / 12.92;
    const float DIV1 = 1. / 1.055;
    const float THRESHOLD = 0.04045;
    const float3 GAMMA = float3(2.4);
        
    float3 condition = float3(color.r < THRESHOLD, color.g < THRESHOLD, color.b < THRESHOLD);
    float3 lowValues = color * DIV12;
    float3 highValues = pow((color + 0.055) * DIV1, GAMMA);
    return condition * lowValues + (1.0 - condition) * highValues;
}

float3 EncodingNonlinearToLinearRGB(float3 color, float gamma) {
    float3 ret;
    ret.r = color.r < 0.0 ? color.r : pow(color.r, gamma);
    ret.g = color.g < 0.0 ? color.g : pow(color.g, gamma);
    ret.b = color.b < 0.0 ? color.b : pow(color.b, gamma);
    return ret;
}

half3 NonlinearToLinearRGB_half(half3 color) {
    const half DIV12 = 1. / 12.92;
    const half DIV1 = 1. / 1.055;
    const half THRESHOLD = 0.04045;
    const half GAMMA = 2.4;
      
    return half3(color.r < THRESHOLD ? (color.r * DIV12) : pow((color.r + 0.055h) * DIV1, GAMMA), color.g < THRESHOLD ? (color.g * DIV12) : pow((color.g + 0.055h) * DIV1, GAMMA), color.b < THRESHOLD ? (color.b * DIV12) : pow((color.b + 0.055h) * DIV1, GAMMA));
}

half3 EncodingNonlinearToLinearRGB_half(half3 color, half gamma) {
    half3 ret;
    ret.r = color.r < 0.0 ? color.r : pow(color.r, gamma);
    ret.g = color.g < 0.0 ? color.g : pow(color.g, gamma);
    ret.b = color.b < 0.0 ? color.b : pow(color.b, gamma);
    return ret;
}

half colorclose_hsv(half3 hsv, half3 keyHsv, half2 tol)
{
    // Saturation or value too low, don't consider it at all.
    if (hsv.b < 0.001 || hsv.g < 0.001) {
        return 1.0;
    }
    half3 weights = half3(4., 1., 2.);
    half tmp = length(weights * (keyHsv - hsv));
    if (tmp < tol.x)
      return 0.0;
   	else if (tmp < tol.y)
      return (tmp - tol.x)/(tol.y - tol.x);
   	else
      return 1.0;
}

half3 rgb2hsv(half3 rgb) {
    half Cmax = max(rgb.r, max(rgb.g, rgb.b));
    half Cmin = min(rgb.r, min(rgb.g, rgb.b));
    half delta = Cmax - Cmin;
    half3 hsv = half3(0., 0., Cmax);

    if(Cmax > Cmin) {
        hsv.y = delta / Cmax;

        if(rgb.r == Cmax) {
            hsv.x = (rgb.g - rgb.b) / delta;
        } else {
            if (rgb.g == Cmax) {
                hsv.x = 2. + (rgb.b - rgb.r) / delta;
            } else {
                hsv.x = 4. + (rgb.r - rgb.g) / delta;
            }
        }
        hsv.x = fract(hsv.x / 6.);
    }
    
    return hsv;
}

half4 videoFrameFragmentShader_common(half3 color_in) {
    half3 color = EncodingNonlinearToLinearRGB_half(color_in, ENCODING_GAMMA);
    
    half4 colorOut = half4(color.rgb, 1.0);
    if (CHROMAKEY_ENABLED) {
        half4 chromaKeyHSV = half4(rgb2hsv(half3(CHROMAKEY_COLOR)), 1.0);
        half4 newHSV = half4(rgb2hsv(color.rgb), 1.0);
        half mask = colorclose_hsv(newHSV.rgb, chromaKeyHSV.rgb, half2(CHROMAKEY_LERP_DIST_RANGE));
        if (!REALITYKIT_ENABLED && mask <= 0.0) {
            discard_fragment();
        }
        
        colorOut = half4((colorOut.rgb * mask) - (half3(CHROMAKEY_COLOR) * (1.0 - mask)), colorOut.a * mask);
        return colorOut;
        //return float4(color.rgb, mask);
    }
    else {
        return colorOut;
    }
    
    // Brighten the scene to examine blocking artifacts/smearing
    //color = pow(color, 1.0 / 2.4);

    /*const float3x3 linearToDisplayP3 = {
        float3(1.2249, -0.0420, -0.0197),
        float3(-0.2247, 1.0419, -0.0786),
        float3(0.0, 0.0, 1.0979),
    };*/
    
    //technically not accurate, since sRGB is below 1.0, but it makes colors pop a bit
    //color = linearToDisplayP3 * color;
}

fragment half4 videoFrameFragmentShader_YpCbCrBiPlanar(ColorInOut in [[stage_in]], texture2d<half> in_tex_y, texture2d<half> in_tex_uv) {
    
    float2 sampleCoord;
    if (FFR_ENABLED) {
        sampleCoord = decompressAxisAlignedCoord(in.texCoord);
    } else {
        sampleCoord = in.texCoord;
    }
    
    constexpr sampler colorSampler(mip_filter::none,
                                   mag_filter::linear,
                                   min_filter::linear);
    half4 ySample = in_tex_y.sample(colorSampler, sampleCoord);
    half4 uvSample = in_tex_uv.sample(colorSampler, sampleCoord);
    half4 ycbcr = half4(ySample.r, uvSample.rg, 1.0f);
    
    const matrix_half4x4 transform = matrix_half4x4(
        half4(ENCODING_YUV_TRANSFORM_0),
        half4(ENCODING_YUV_TRANSFORM_1),
        half4(ENCODING_YUV_TRANSFORM_2),
        half4(ENCODING_YUV_TRANSFORM_3)
    );
    
    half3 rgb_uncorrect = half3((transform * ycbcr).rgb);
    half3 color = NonlinearToLinearRGB_half(rgb_uncorrect);
    
    return videoFrameFragmentShader_common(color);
}

fragment half4 videoFrameFragmentShader_SecretYpCbCrFormats(ColorInOut in [[stage_in]], texture2d<half> in_tex_y) {
    
    float2 sampleCoord;
    if (FFR_ENABLED) {
        sampleCoord = decompressAxisAlignedCoord(in.texCoord);
    } else {
        sampleCoord = in.texCoord;
    }
    
    constexpr sampler colorSampler(mip_filter::none,
                                   mag_filter::linear,
                                   min_filter::linear);
    
    half3 color = in_tex_y.sample(colorSampler, sampleCoord).rgb;
    
    return videoFrameFragmentShader_common(color);
}

fragment float4 videoFrameDepthFragmentShader(ColorInOut in [[stage_in]], texture2d<float> in_tex_y, texture2d<float> in_tex_uv) {
    return float4(0.0, 0.0, 0.0, 0.0);
}

struct CopyVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CopyVertexOut copyVertexShader(constant VertexPosOnly* inArr [[buffer(BufferIndexMeshPositions)]], uint vertexID [[vertex_id]], constant rasterization_rate_map_data &vrr [[buffer(BufferIndexVRR)]]) {
    CopyVertexOut out;
    rasterization_rate_map_decoder map(vrr);
    
    // generate vertices in-shader, not sure if fast or slow tbh
    /*const uint gridSize = 128;

    ushort x = (vertexID >> 1) % gridSize;
    ushort y = (vertexID & 1) + (((vertexID >> 1) / gridSize) % (gridSize-1));
    ushort idx = (vertexID >= (gridSize-1)*gridSize*2) ? 1 : 0;
    float otherEye = idx ? 1.0 : 0.0;

    // Normalize coordinates to the range [0, 1]
    float2 uv = float2(
        (float(x) / float(gridSize - 1)),
        (float(y) / float(gridSize - 1))
    );

    // Normalize coordinates to the range [-1, 1]ish
    out.position = float4((uv * float2(2.0, -1.0)) + float2(-1.0, otherEye), otherEye, 1.0);
    out.uv = map.map_screen_to_physical_coordinates(uv * VRR_SCREEN_SIZE, idx);*/
    
    float2 uv = inArr[vertexID].position.xy;
    float otherEye = inArr[vertexID].position.z;
    ushort idx = (otherEye != 0.0) ? 1.0 : 0.0;
    out.position = float4((uv * float2(2.0, -1.0)) + float2(-1.0, otherEye), otherEye, 1.0);
    out.uv = map.map_screen_to_physical_coordinates(uv * VRR_SCREEN_SIZE, idx);
    
    return out;
}

//constant rasterization_rate_map_data &vrr [[buffer(BufferIndexVRR)]]
fragment half4 copyFragmentShader(CopyVertexOut in [[stage_in]], texture2d_array<half> in_tex) {
    constexpr sampler colorSampler(coord::pixel,
                    address::clamp_to_edge,
                    filter::linear);
    ushort idx = in.position.z != 0.0 ? 1 : 0;
    
    half4 color = in_tex.sample(colorSampler, in.uv, idx);
    //half4 color = half4(in.uv.x, in.uv.y, 0.0, 1.0);

    return color;
}
