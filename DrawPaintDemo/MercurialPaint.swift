//
//  MercurialPaint.swift
//  DrawPaintDemo
//
//  Created by liupeng on 10/07/2017.
//  Copyright © 2017 liupeng. All rights reserved.
//

import UIKit
import MetalKit
import MetalPerformanceShaders

enum XY
{
    case X, Y
}

let particleCount: Int = 2048

class MercurialPaint: UIView {
    
    let device = MTLCreateSystemDefaultDevice()!
    // MARK: UI components
    
    var metalView: MTKView!
    let alignment:Int = 0x4000
    let particlesMemoryByteSize:Int = particleCount * MemoryLayout<Int>.size
    let halfPi = CGFloat(M_PI_2)
    
    private var touchLocations = [CGPoint](repeating: CGPoint(x: -1, y: -1), count: 4)
    private var touchForce:Float = 0
    
    private var isDrawing = false
    {
        didSet
        {
            if isDrawing
            {
                metalView.isPaused = false
            }
        }
    }
    
    
    // MARK: Lazy variables
    
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: MTLPixelFormat.rgba8Unorm,
                                                                                    width: 750,
                                                                                    height: 1334,
                                                                                    mipmapped: false)
    
    lazy var paintingTexture: MTLTexture =
        {
            [unowned self] in
            
            return self.device.makeTexture(descriptor: self.textureDescriptor)
            }()!
    
    lazy var intermediateTexture: MTLTexture =
        {
            [unowned self] in
            
            return self.device.makeTexture(descriptor: self.textureDescriptor)
            }()!
    
    lazy var paintingShaderPipelineState: MTLComputePipelineState =
        {
            [unowned self] in
            
            do
            {
                let library = self.device.makeDefaultLibrary()!
                
                let kernelFunction = library.makeFunction(name: "mercurialPaintShader")
                let pipelineState = try self.device.makeComputePipelineState(function: kernelFunction!)
                
                return pipelineState
            }
            catch
            {
                fatalError("Unable to create censusTransformMonoPipelineState")
            }
            }()
    
    lazy var commandQueue: MTLCommandQueue =
        {
            [unowned self] in
            
            return self.device.makeCommandQueue()
            }()!
    
    lazy var blur: MPSImageGaussianBlur =
        {
            [unowned self] in
            
            return MPSImageGaussianBlur(device: self.device, sigma: 3)
            }()
    
    lazy var threshold: MPSImageThresholdBinary =
        {
            [unowned self] in
            
            return MPSImageThresholdBinary(device: self.device, thresholdValue: 0.5, maximumValue: 1, linearGrayColorTransform: nil)
            }()
    
    
    
    // MARK: Private variables
    
    private var threadsPerThreadgroup:MTLSize!
    private var threadgroupsPerGrid:MTLSize!
    
    private var particlesMemory:UnsafeMutableRawPointer? = nil
    private var particlesVoidPtr: OpaquePointer!
    private var particlesParticlePtr: UnsafeMutablePointer<Int>!
    private var particlesParticleBufferPtr: UnsafeMutableBufferPointer<Int>!
    
    private var particlesBufferNoCopy: MTLBuffer!
    
    // MARK: Initialisation
    
    override init(frame frameRect: CGRect)
    {
        super.init(frame: frameRect)
        
        metalView = MTKView(frame: CGRect(x: 0, y: 0, width: 750, height: 1334), device: device)
        
        metalView.framebufferOnly = false
        metalView.colorPixelFormat = MTLPixelFormat.bgra8Unorm
        
        metalView.delegate = self
        
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 1
        
        metalView.drawableSize = CGSize(width: 2048, height: 2048)
        
        addSubview(metalView)
        
        setUpMetal()
        
        metalView.isPaused = true
        
    }
    required init(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setUpMetal()
    {
        posix_memalign(&particlesMemory, alignment, particlesMemoryByteSize)
        
        particlesVoidPtr = OpaquePointer(particlesMemory)
        particlesParticlePtr = UnsafeMutablePointer<Int>(particlesVoidPtr)
        particlesParticleBufferPtr = UnsafeMutableBufferPointer(start: particlesParticlePtr, count: particleCount)
        
        for index in particlesParticleBufferPtr.startIndex ..< particlesParticleBufferPtr.endIndex
        {
            particlesParticleBufferPtr[index] = Int(arc4random_uniform(9999))
        }
        
        let threadExecutionWidth = paintingShaderPipelineState.threadExecutionWidth
        
        threadsPerThreadgroup = MTLSize(width:threadExecutionWidth,height:1,depth:1)
        threadgroupsPerGrid = MTLSize(width:particleCount / threadExecutionWidth, height:1, depth:1)
        
        particlesBufferNoCopy = device.makeBuffer(bytesNoCopy: particlesMemory!,
                                                                length: Int(particlesMemoryByteSize),
                                                                options: MTLResourceOptions.storageModeShared,
                                                                deallocator: nil)
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else
        {
            return
        }
        
        touchForce = touch.type == .stylus
            ? Float(touch.force / touch.maximumPossibleForce)
            : 0.5
        
        touchLocations = [touch.location(in: self)]
        
        isDrawing = true
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let coalescedTouches =  event?.coalescedTouches(for: touch) else
        {
            return
        }
        
        touchForce = touch.type == .stylus
            ? Float(touch.force / touch.maximumPossibleForce)
            : 0.5
        
        touchLocations = coalescedTouches.map{ return $0.location(in: self) }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchLocations = [CGPoint](repeating: CGPoint(x: -1, y: -1), count: 4)
        
        isDrawing = false
    }
    
    
    func touchLocationsToVector(_ xy: XY) -> vector_int4
    {
        func getValue(_ point: CGPoint, xy: XY) -> Int32
        {
            switch xy
            {
            case .X:
                return Int32(point.x * 2)
            case .Y:
                return Int32(point.y * 2)
            }
        }
        
        let x = touchLocations.count > 0 ? getValue(touchLocations[0], xy: xy) : -1
        let y = touchLocations.count > 1 ? getValue(touchLocations[1], xy: xy) : -1
        let z = touchLocations.count > 2 ? getValue(touchLocations[2], xy: xy) : -1
        let w = touchLocations.count > 3 ? getValue(touchLocations[3], xy: xy) : -1
        
        let returnValue = vector_int4(x, y, z, w)
        
        return returnValue
    }
}

extension MercurialPaint: MTKViewDelegate
{
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
    
    func draw(in view: MTKView) {
        
        let commandBuffer = commandQueue.makeCommandBuffer()
        let commandEncoder = commandBuffer?.makeComputeCommandEncoder()
        
        commandEncoder?.setComputePipelineState(paintingShaderPipelineState)
        
        commandEncoder?.setBuffer(particlesBufferNoCopy, offset: 0, index: 0)
        
        var xLocation = touchLocationsToVector(.X)
        let xLocationBuffer = device.makeBuffer(bytes: &xLocation,
                                                length: MemoryLayout<vector_int4>.size,
                                                        options: MTLResourceOptions.optionCPUCacheModeWriteCombined)
        var yLocation = touchLocationsToVector(.Y)
        let yLocationBuffer = device.makeBuffer(bytes: &yLocation,
                                                length: MemoryLayout<vector_int4>.size,
                                                        options: MTLResourceOptions.optionCPUCacheModeWriteCombined)
        
        let touchForceBuffer = device.makeBuffer(bytes: &touchForce,
                                                 length: MemoryLayout<Float>.size,
                                                         options: MTLResourceOptions.optionCPUCacheModeWriteCombined)
        
        commandEncoder?.setBuffer(xLocationBuffer, offset: 0, index: 1)
        commandEncoder?.setBuffer(yLocationBuffer, offset: 0, index: 2)
        commandEncoder?.setBuffer(touchForceBuffer, offset: 0, index: 3)
        
        commandEncoder?.setTexture(paintingTexture, index: 0)
        
        commandEncoder?.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        
        commandEncoder?.endEncoding()
        
        guard let drawable = metalView.currentDrawable else
        {
            print("currentDrawable returned nil")
            
            return
        }
        
        blur.encode(commandBuffer: commandBuffer!,
                                   sourceTexture: paintingTexture,
                                   destinationTexture: intermediateTexture)
        
        threshold.encode(commandBuffer: commandBuffer!,
                                        sourceTexture: intermediateTexture,
                                        destinationTexture: drawable.texture)
        
        commandBuffer?.commit()
        
        drawable.present()
        
        view.isPaused = !isDrawing
    }
}


