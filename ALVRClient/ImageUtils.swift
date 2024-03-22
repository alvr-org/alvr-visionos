//
//  ImageUtils.swift
//
//  Created by @xuhao1 on 2024/3/17.
//

import Foundation
import CoreGraphics
import ImageIO
import Metal
import MetalFX
import CoreGraphics
import MobileCoreServices

func saveCGImageToFile(image: CGImage, url: URL, format: CFString = kUTTypePNG) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format, 1, nil) else {
        print("Failed to create CGImageDestination for URL: \(url)")
        return
    }

    CGImageDestinationAddImage(destination, image, nil)

    // Finalize the image destination to actually write the data to file
    if !CGImageDestinationFinalize(destination) {
        print("Failed to save image to URL: \(url)")
    } else {
        print("Image successfully saved to URL: \(url)")
    }
}

class YUV2RGBConverter
{
    var computePipelineState: MTLComputePipelineState!
    var device: MTLDevice!
    var outputTexture: MTLTexture? = nil
    
    init?(device: MTLDevice)
    {
        // Assuming `device` is your MTLDevice instance and you've set it up already
        self.device = device
        let defaultLibrary = device.makeDefaultLibrary()!
        let kernelFunction = defaultLibrary.makeFunction(name: "yuvToRgbComputeKernel")
        do {
            computePipelineState = try device.makeComputePipelineState(function: kernelFunction!)
        }
        catch {
            print("shader failed")
        }
    }
    
    func addToBuffer(commandBuffer: MTLCommandBuffer, metalY: MTLTexture, metalUV: MTLTexture) -> MTLTexture? {
        // Prepare the output texture with the same dimensions as the Y texture
        if (outputTexture == nil)
        {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                             width: metalY.width,
                                                                             height: metalY.height,
                                                                             mipmapped: false)
            textureDescriptor.usage = [.shaderWrite, .shaderRead]
            self.outputTexture = device.makeTexture(descriptor: textureDescriptor)
            if self.outputTexture == nil {
                print("Failed to create output texture")
                return nil
            }
        }
        
        guard let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder() else {
          print("Failed to create command encoder")
          return nil
        }
    
        computeCommandEncoder.setComputePipelineState(computePipelineState)
        computeCommandEncoder.setTexture(metalY, index: 0)
        computeCommandEncoder.setTexture(metalUV, index: 1)
        computeCommandEncoder.setTexture(outputTexture, index: 2)
        
        // Calculate the number of threads per threadgroup and the number of threadgroups
        let threadGroupCount = MTLSize(width: 8, height: 8, depth: 1)
        let threadGroups = MTLSize(width: (metalY.width + threadGroupCount.width - 1) / threadGroupCount.width,
                                   height: (metalY.height + threadGroupCount.height - 1) / threadGroupCount.height,
                                   depth: 1)
        
        // Encode the compute command and dispatch it
        computeCommandEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupCount)
        computeCommandEncoder.endEncoding()
        return self.outputTexture
    }
    
    func convert(metalY: MTLTexture, metalUV: MTLTexture) -> MTLTexture? {
        
        // Prepare the command buffer and command encoder
        guard let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("Failed to create command encoder")
            return nil
          }
        
        let outputTexture = addToBuffer(commandBuffer: commandBuffer, metalY:metalY, metalUV: metalUV)
        // Commit the command buffer and wait for it to complete
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return outputTexture
    }
}

func GPUTextureToImage(texture: MTLTexture, device: MTLDevice) -> CGImage? {
    let width = texture.width
    let height = texture.height
    let pixelByteCount = 4 * width * height

    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    textureDescriptor.usage = [.shaderRead, .pixelFormatView]
    textureDescriptor.storageMode = .shared

    guard let sharedTexture = device.makeTexture(descriptor: textureDescriptor) else {
        print("Failed to create shared texture")
        return nil
    }

    guard let commandQueue = device.makeCommandQueue(),
          let commandBuffer = commandQueue.makeCommandBuffer(),
          let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        print("Failed to create command queue or command buffer")
        return nil
    }

    blitEncoder.copy(from: texture,
                     sourceSlice: 0,
                     sourceLevel: 0,
                     sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                     to: sharedTexture,
                     destinationSlice: 0,
                     destinationLevel: 0,
                     destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blitEncoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    // Prepare to read the texture data
    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 0, count: Int(pixelByteCount))
    sharedTexture.getBytes(&data, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

    let providerRef = CGDataProvider(data: NSData(bytes: &data, length: data.count))
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    let colorSpaceRef = CGColorSpaceCreateDeviceRGB()

    guard let cgImage = CGImage(width: width,
                                height: height,
                                bitsPerComponent: 8,
                                bitsPerPixel: 32,
                                bytesPerRow: bytesPerRow,
                                space: colorSpaceRef,
                                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                provider: providerRef!,
                                decode: nil,
                                shouldInterpolate: true,
                                intent: CGColorRenderingIntent.defaultIntent) else {
        return nil
    }

    return cgImage
}


func textureToImage(texture: MTLTexture) -> CGImage? {
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * texture.width
    let imageByteCount = bytesPerRow * texture.height
    let imageBytes = UnsafeMutableRawPointer.allocate(byteCount: imageByteCount, alignment: bytesPerPixel)
    defer {
        imageBytes.deallocate()
    }

    // Create a region that covers the entire texture
    let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
    // Read the texture data into the allocated bytes
    texture.getBytes(imageBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

    // Create a CGImage from the bytes
    let providerRef = CGDataProvider(data: NSData(bytesNoCopy: imageBytes, length: imageByteCount, freeWhenDone: true))
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let cgImage = CGImage(width: texture.width,
                                height: texture.height,
                                bitsPerComponent: 8,
                                bitsPerPixel: 32,
                                bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: bitmapInfo,
                                provider: providerRef!,
                                decode: nil,
                                shouldInterpolate: false,
                                intent: CGColorRenderingIntent.defaultIntent) else {
        return nil
    }
    return cgImage
}

