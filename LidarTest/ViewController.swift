//
//  ViewController.swift
//  LidarTest
//
//  Created by Fabio Dela Antonio on 07/02/2022.
//

import UIKit
import SceneKit
import ARKit

final class ViewController: UIViewController {

    @IBOutlet var sceneView: ARSCNView!

    let horizontalPoints = 256 / 2
    let verticalPoints = 192 / 2

    var scene = SCNScene()
    var depthNodes = [SCNNode]()
    var parentDebugNodes = SCNNode()

    var shouldCaptureNextFrame = false

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Set the view's delegate
        sceneView.delegate = self
        sceneView.session.delegate = self

        setupScene()

        // Set the scene to the view
        sceneView.scene = scene
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics = .smoothedSceneDepth

        // Run the view's session
        sceneView.session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        sceneView.session.pause()
    }

    @IBAction func captureAction(_ sender: Any) {
        shouldCaptureNextFrame = true
    }
}

// MARK: - ARSCNViewDelegate

extension ViewController: ARSessionDelegate, ARSCNViewDelegate {

    func session(_ session: ARSession, didUpdate frame: ARFrame) {

        guard shouldCaptureNextFrame,
              let smoothedDepth = try? frame.smoothedSceneDepth?.depthMap.copy(),
              let capturedImage = try? frame.capturedImage.copy()
        else {
            return
        }

        DispatchQueue.main.async {
            self.updateGeometry(smoothedDepth: smoothedDepth, capturedImage: capturedImage, camera: frame.camera)
        }

        shouldCaptureNextFrame = false
    }

    func updateGeometry(smoothedDepth: CVPixelBuffer, capturedImage: CVPixelBuffer, camera: ARCamera) {
        let lockFlags = CVPixelBufferLockFlags.readOnly
        CVPixelBufferLockBaseAddress(smoothedDepth, lockFlags)
        defer {
            CVPixelBufferUnlockBaseAddress(smoothedDepth, lockFlags)
        }

        CVPixelBufferLockBaseAddress(capturedImage, lockFlags)
        defer {
            CVPixelBufferUnlockBaseAddress(capturedImage, lockFlags)
        }

        let baseAddress = CVPixelBufferGetBaseAddressOfPlane(smoothedDepth, 0)!
        let depthByteBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

        let lumaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(capturedImage, 0)!
        let lumaByteBuffer = lumaBaseAddress.assumingMemoryBound(to: UInt8.self)

        let chromaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(capturedImage, 1)!
        let chromaByteBuffer = chromaBaseAddress.assumingMemoryBound(to: UInt16.self)

        // The `.size` accessor simply read the CVPixelBuffer's width and height in pixels.
        //
        // They are the same ratio:
        // 1920 x 1440 = 1440 x 1920 = 0.75
        let depthMapSize = smoothedDepth.size(ofPlane: 0)
        // 192 x 256 = 0.75
        let capturedImageSize = capturedImage.size(ofPlane: 0)
        let lumaSize = capturedImageSize
        let chromaSize = capturedImage.size(ofPlane: 1)

        var cameraIntrinsics = camera.intrinsics
        let depthResolution = simd_float2(x: Float(depthMapSize.x), y: Float(depthMapSize.y))
        let scaleRes = simd_float2(x: Float(capturedImageSize.x) / depthResolution.x,
                                   y: Float(capturedImageSize.y) / depthResolution.y )
        // Make the camera intrinsics be with respect to Depth.
        cameraIntrinsics[0][0] /= scaleRes.x
        cameraIntrinsics[1][1] /= scaleRes.y

        cameraIntrinsics[2][0] /= scaleRes.x
        cameraIntrinsics[2][1] /= scaleRes.y

        // This will be the long size, because of the rotation
        let horizontalStep = Float(depthMapSize.x) / Float(self.horizontalPoints)
        let halfHorizontalStep = horizontalStep / 2
        // This will be the short size, because of the rotation
        let verticalStep = Float(depthMapSize.y) / Float(self.verticalPoints)
        let halfVerticalStep = verticalStep / 2

        let depthWidthToLumaWidth = Float(lumaSize.x)/Float(depthMapSize.x)
        let depthHeightToLumaHeight = Float(lumaSize.y)/Float(depthMapSize.y)

        let depthWidthToChromaWidth = Float(chromaSize.x)/Float(depthMapSize.x)
        let depthHeightToChromaHeight = Float(chromaSize.y)/Float(depthMapSize.y)

         for h in 0..<horizontalPoints {
            for v in 0..<verticalPoints {
                let x = Float(h) * horizontalStep + halfHorizontalStep
                let y = Float(v) * verticalStep + halfVerticalStep
                let depthMapPoint = simd_float2(x, y)

                // Sample depth
                let metricDepth = sampleDepthRaw(depthByteBuffer, size: depthMapSize, at: .init(depthMapPoint))

                let wp = worldPoint(depthMapPixelPoint: depthMapPoint,
                                    depth: metricDepth,
                                    cameraIntrinsics: cameraIntrinsics,
                                    // This is crucial: you need to always use the view matrix for Landscape Right.
                                    viewMatrixInverted: camera.viewMatrix(for: .landscapeRight).inverse)


                // Sample Image
                let lumaPoint = simd_float2(x * depthWidthToLumaWidth, y * depthHeightToLumaHeight)
                let luma = sampleLuma(lumaByteBuffer, size: lumaSize, at: .init(lumaPoint))

                let chromaPoint = simd_float2(x * depthWidthToChromaWidth, y * depthHeightToChromaHeight)
                let chroma = sampleChroma(chromaByteBuffer, size: chromaSize, at: .init(chromaPoint))

                let cr = UInt8(chroma >> 8)
                let cb = UInt8((chroma << 8) >> 8)

                let node = self.depthNodes[v * horizontalPoints + h]
                node.simdWorldPosition = wp
                node.geometry?.materials.first?.diffuse.contents = UIColor(y: luma, cb: cb, cr: cr)
            }
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        // Present an error message to the user
        
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay
        
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required
        
    }
}

extension ViewController {

    func setupScene() {
        scene.rootNode.addChildNode(parentDebugNodes)

        let sizeGeomPredictions = 0.005

        for _ in 0 ..< (horizontalPoints * verticalPoints) {
            let geom = SCNBox(width: sizeGeomPredictions, height: sizeGeomPredictions, length: sizeGeomPredictions, chamferRadius: 0)
            geom.firstMaterial?.diffuse.contents = UIColor.green

            let node = SCNNode(geometry: geom)
            parentDebugNodes.addChildNode(node)
            depthNodes.append(node)
        }
    }

    func sampleLuma(_ pointer: UnsafeMutablePointer<UInt8>, size: SIMD2<Int>, at: SIMD2<Int>) -> UInt8 {
        let baseAddressIndex = at.y * size.x + at.x
        return UInt8(pointer[baseAddressIndex])
    }

    func sampleChroma(_ pointer: UnsafeMutablePointer<UInt16>, size: SIMD2<Int>, at: SIMD2<Int>) -> UInt16 {
        let baseAddressIndex = at.y * size.x + at.x
        return UInt16(pointer[baseAddressIndex])
    }

    func sampleDepthRaw(_ pointer: UnsafeMutablePointer<Float32>, size: SIMD2<Int>, at: SIMD2<Int>) -> Float {
        let baseAddressIndex = at.y * size.x + at.x
        return Float(pointer[baseAddressIndex])
    }

    // This also works. Adapted from:
    // https://developer.apple.com/forums/thread/676368
    func worldPoint(
        depthMapPixelPoint: SIMD2<Float>,
        depth: Float,
        cameraIntrinsicsInverted: simd_float3x3,
        viewMatrixInverted: simd_float4x4
    ) -> SIMD3<Float> {
         let localPoint = cameraIntrinsicsInverted * simd_float3(depthMapPixelPoint, 1) * -depth
         let localPointSwappedX = simd_float3(-localPoint.x, localPoint.y, localPoint.z)
         let worldPoint = viewMatrixInverted * simd_float4(localPointSwappedX, 1)
         return (worldPoint / worldPoint.w)[SIMD3(0,1,2)]
    }

    // This one is adapted from:
    // http://nicolas.burrus.name/index.php/Research/KinectCalibration
    func worldPoint(depthMapPixelPoint: SIMD2<Float>, depth: Float, cameraIntrinsics: simd_float3x3, viewMatrixInverted: simd_float4x4) -> SIMD3<Float> {
        let xrw = ((depthMapPixelPoint.x - cameraIntrinsics[2][0]) * depth / cameraIntrinsics[0][0])
        let yrw = (depthMapPixelPoint.y - cameraIntrinsics[2][1]) * depth / cameraIntrinsics[1][1]
        // Y is UP in camera space, vs it being DOWN in image space.
        let localPoint = simd_float3(xrw, -yrw, -depth)
        let worldPoint = viewMatrixInverted * simd_float4(localPoint, 1)
        return simd_float3(worldPoint.x, worldPoint.y, worldPoint.z)
    }
}

extension CVPixelBuffer {

    func size(ofPlane plane: Int = 0) -> SIMD2<Int> {
        let width = CVPixelBufferGetWidthOfPlane(self, plane)
        let height = CVPixelBufferGetHeightOfPlane(self, plane)
        return  .init(x: width, y: height)
    }
}

extension UIColor {

    private static let encoding: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.299, 0.587, 0.114)

    convenience init(y: UInt8, cb: UInt8, cr: UInt8, alpha: CGFloat = 1.0) {
        let Y  = (Double(y)  / 255.0)
        let Cb = (Double(cb) / 255.0) - 0.5
        let Cr = (Double(cr) / 255.0) - 0.5

        let k = UIColor.encoding
        let kr = (Cr * ((1.0 - k.r) / 0.5))
        let kgb = (Cb * ((k.b * (1.0 - k.b)) / (0.5 * k.g)))
        let kgr = (Cr * ((k.r * (1.0 - k.r)) / (0.5 * k.g)))
        let kb = (Cb * ((1.0 - k.b) / 0.5))

        let r = Y + kr
        let g = Y - kgb - kgr
        let b = Y + kb

        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

enum PixelBufferCopyError: Error {
    case allocationFailed
}

extension CVPixelBuffer {

    func copy() throws -> CVPixelBuffer {
        precondition(CFGetTypeID(self) == CVPixelBufferGetTypeID(), "copy() cannot be called on a non-CVPixelBuffer")

        var _copy: CVPixelBuffer?

        let width = CVPixelBufferGetWidth(self)
        let height = CVPixelBufferGetHeight(self)
        let formatType = CVPixelBufferGetPixelFormatType(self)
        let attachments = CVBufferCopyAttachments(self, .shouldPropagate)

        CVPixelBufferCreate(nil, width, height, formatType, attachments, &_copy)

        guard let copy = _copy else {
            throw PixelBufferCopyError.allocationFailed
        }

        CVPixelBufferLockBaseAddress(self, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])

        defer {
            CVPixelBufferUnlockBaseAddress(copy, [])
            CVPixelBufferUnlockBaseAddress(self, .readOnly)
        }

        let pixelBufferPlaneCount: Int = CVPixelBufferGetPlaneCount(self)


        if pixelBufferPlaneCount == 0 {
            let dest = CVPixelBufferGetBaseAddress(copy)
            let source = CVPixelBufferGetBaseAddress(self)
            let height = CVPixelBufferGetHeight(self)
            let bytesPerRowSrc = CVPixelBufferGetBytesPerRow(self)
            let bytesPerRowDest = CVPixelBufferGetBytesPerRow(copy)
            if bytesPerRowSrc == bytesPerRowDest {
                memcpy(dest, source, height * bytesPerRowSrc)
            }else {
                var startOfRowSrc = source
                var startOfRowDest = dest
                for _ in 0..<height {
                    memcpy(startOfRowDest, startOfRowSrc, min(bytesPerRowSrc, bytesPerRowDest))
                    startOfRowSrc = startOfRowSrc?.advanced(by: bytesPerRowSrc)
                    startOfRowDest = startOfRowDest?.advanced(by: bytesPerRowDest)
                }
            }

        }else {
            for plane in 0 ..< pixelBufferPlaneCount {
                let dest        = CVPixelBufferGetBaseAddressOfPlane(copy, plane)
                let source      = CVPixelBufferGetBaseAddressOfPlane(self, plane)
                let height      = CVPixelBufferGetHeightOfPlane(self, plane)
                let bytesPerRowSrc = CVPixelBufferGetBytesPerRowOfPlane(self, plane)
                let bytesPerRowDest = CVPixelBufferGetBytesPerRowOfPlane(copy, plane)

                if bytesPerRowSrc == bytesPerRowDest {
                    memcpy(dest, source, height * bytesPerRowSrc)
                }else {
                    var startOfRowSrc = source
                    var startOfRowDest = dest
                    for _ in 0..<height {
                        memcpy(startOfRowDest, startOfRowSrc, min(bytesPerRowSrc, bytesPerRowDest))
                        startOfRowSrc = startOfRowSrc?.advanced(by: bytesPerRowSrc)
                        startOfRowDest = startOfRowDest?.advanced(by: bytesPerRowDest)
                    }
                }
            }
        }
        return copy
    }
}
