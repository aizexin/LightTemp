import UIKit
import AVFoundation
import Photos
import Foundation
import ChameleonFramework

class ViewController: UIViewController, AVCapturePhotoCaptureDelegate {

    @IBOutlet weak var kLabel: UILabel!
    @IBOutlet weak var colorView: UIView!
    @IBOutlet weak var videoPreviewView: VideoPreviewView!

    var captureSession: AVCaptureSession!
    var capturePhotoOutput: AVCapturePhotoOutput!
    var isCaptureSessionConfigured = false
    var photoSampleBuffer: CMSampleBuffer!
    var rawSampleBuffer: CMSampleBuffer!

    override func viewDidLoad() {
        super.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if self.isCaptureSessionConfigured {
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
            }
        } else {
            configureCaptureSession { (success) in
                print("configureCaptureSession: \(success)")

                guard success else { return }

                self.videoPreviewView.session = self.captureSession
                self.isCaptureSessionConfigured = true
                self.captureSession.startRunning()
                DispatchQueue.main.async {
                    self.videoPreviewView.updateVideoOrientationForDeviceOrientation()
                }
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    @IBAction func takePhoto(_ sender: UIButton) {
        snapPhoto()
    }

    func defaultDevice() -> AVCaptureDevice {
        if let device = AVCaptureDevice.default(AVCaptureDevice.DeviceType.builtInDualCamera, for: AVMediaType.video, position: AVCaptureDevice.Position.back) {
            let incandescentLightCompensation = 3_000
            let tint = 0 // 不调节
            let temperatureAndTintValues = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(incandescentLightCompensation), tint: Float(tint))
            let deviceGains = device.deviceWhiteBalanceGains(for: temperatureAndTintValues)
            if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                device.setWhiteBalanceModeLocked(with: deviceGains) {
                    (timestamp:CMTime) -> Void in
                }
            }
            return device // use default back facing camera otherwise
        } else {
            fatalError("All supported devices are expected to have at least one of the queried capture devices.")
        }
        
    }

    func configureCaptureSession(_ completionHandler: ((_ success: Bool) -> Void)) {
        self.captureSession = AVCaptureSession()

        var success = false
        defer { completionHandler(success) } // Ensure all exit paths call completion handler.

        // Get video input for the default camera.
        let videoCaptureDevice = defaultDevice()
        guard let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            print("Unable to obtain video input for default camera.")
            return
        }

        // Create and configure the photo output.
        let capturePhotoOutput = AVCapturePhotoOutput()

        // Make sure inputs and output can be added to session.
        guard self.captureSession.canAddInput(videoInput) else { return }
        guard self.captureSession.canAddOutput(capturePhotoOutput) else { return }

        // Configure the session.
        self.captureSession.beginConfiguration()
        self.captureSession.sessionPreset = AVCaptureSession.Preset.photo
        self.captureSession.addInput(videoInput)
        self.captureSession.addOutput(capturePhotoOutput)
        self.captureSession.commitConfiguration()
        
        self.capturePhotoOutput = capturePhotoOutput
        
        success = true
    }

    func snapPhoto() {
        guard let capturePhotoOutput = self.capturePhotoOutput else { return }
        let videoPreviewLayerOrientation = videoPreviewView.videoPreviewLayer.connection?.videoOrientation

        // Update the photo output's connection to match the video orientation of the video preview layer.
        if let photoOutputConnection = capturePhotoOutput.connection(with: AVMediaType.video) {
            photoOutputConnection.videoOrientation = videoPreviewLayerOrientation!
        }

        let photoSettings = createSetting()

        capturePhotoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    func createSetting() -> AVCapturePhotoSettings {

        let photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey : AVVideoCodecJPEG, AVVideoCompressionPropertiesKey : [AVVideoQualityKey : 1.0]] as [String : Any])

        photoSettings.flashMode = .off

        return photoSettings
    }

    func makeUniqueTempFileURL(typeExtension: String) -> URL {
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).\(typeExtension)")
    }

    func saveRAWPlusJPEGPhotoLibrary(rawSampleBuffer: CMSampleBuffer?,
                                     photoSampleBuffer: CMSampleBuffer,
                                     completionHandler: ((_ success: Bool, _ error: Error?) -> Void)?) {
        guard let jpegData = AVCapturePhotoOutput.jpegPhotoDataRepresentation(
            forJPEGSampleBuffer: photoSampleBuffer,
            previewPhotoSampleBuffer: nil)
            else {
                print("Unable to create JPEG data.")
                completionHandler?(false, nil)
                return
        }
        
        //获得照片平均色
        let image = UIImage.init(data: jpegData)
        let averageColor = AverageColorFromImage(image!)
        self.colorView.backgroundColor = averageColor
        self.kLabel.text = "\(getTempWith(hexString: averageColor.hexValue()))"
        
    }

    public func photoOutput(_ captureOutput: AVCapturePhotoOutput,
                            didFinishProcessingPhoto photoSampleBuffer: CMSampleBuffer?,
                            previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?,
                        resolvedSettings: AVCaptureResolvedPhotoSettings,
                        bracketSettings: AVCaptureBracketedStillImageSettings?,
                        error: Error?) {
        guard error == nil, let photoSampleBuffer = photoSampleBuffer else {
            print("Error capturing photo: \(String(describing: error))")
            return
        }

        self.photoSampleBuffer = photoSampleBuffer
    }

    func photoOutput(_ captureOutput: AVCapturePhotoOutput,
                     didFinishProcessingRawPhoto rawSampleBuffer: CMSampleBuffer?,
                     previewPhoto previewPhotoSampleBuffer: CMSampleBuffer?,
                 resolvedSettings: AVCaptureResolvedPhotoSettings,
                 bracketSettings: AVCaptureBracketedStillImageSettings?,
                 error: Error?) {
        guard error == nil, let rawSampleBuffer = rawSampleBuffer else {
            print("Error capturing raw photo: \(String(describing: error))")
            return
        }

        self.rawSampleBuffer = rawSampleBuffer
    }

    public func photoOutput(_ captureOutput: AVCapturePhotoOutput,
                            didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                        error: Error?) {
        guard error == nil else {
            print("Error in capture process: \(String(describing: error))")
            return
        }

        if  let photoSampleBuffer = self.photoSampleBuffer {
            saveRAWPlusJPEGPhotoLibrary(rawSampleBuffer: rawSampleBuffer,
                                        photoSampleBuffer: photoSampleBuffer,
                                        completionHandler: { success, error in
                    if success {
                        print("Added RAW+JPEG photo to library.")
                    } else {
                        print("Error adding RAW+JPEG photo to library: \(String(describing: error))")
                    }
            })
        } else {
            print("-------")
        }
    }
    
    func getTempWith(hexString: String) -> CGFloat {

        let hexString = (hexString as NSString).replacingOccurrences(of: "#", with: "")
        
        print("hexString= \(hexString)")
        let rString = (hexString as NSString).substring(to: 2)
        let gString = (hexString as NSString).substring(with: NSRange.init(location: 2, length: 2))
        let bString = (hexString as NSString).substring(with: NSRange.init(location: 4, length: 2))
        
        let R  = Float(hexStringToInt(from: rString))
        let G  = Float(hexStringToInt(from: gString))
        let B  = Float(hexStringToInt(from: bString))
        
//        let xCoordinate = 2.7689 * rvalue + 1.75157 * gvalue + 1.1302 * bvalue
//        let yCoordinate = rvalue + 4.5907 * gvalue + 0.0601 * bvalue
////        let zCoordinate = 0.0565 * gvalue + 5.5943 * bvalue
        let X = (-0.14282) * (R) + (1.54924) * (G) + (-0.95641) * (B)
        let Y = (-0.32466) * (R) + (1.57837) * (G) + (-0.73191) * (B)
        let Z = (-0.68202) * (R) + (0.77073) * (G) + (0.56332) * (B)
        
        let x = X/(X+Y+Z)
        let y = Y/(X+Y+Z)
        let n = (x - 0.3320)/(0.1858 - y)
        let cct = 449 * powf(n, 3) + 3525 * powf(n, 2) + 6823.3 * n + 5520.33
        
        return CGFloat(cct)
    }
    
    func hexStringToInt(from:String) -> Int {
        let str = from.uppercased()
        var sum = 0
        for i in str.utf8 {
            sum = sum * 16 + Int(i) - 48 // 0-9 从48开始
            if i >= 65 {                 // A-Z 从65开始，但有初始值10，所以应该是减去55
                sum -= 7
            }
        }
        return sum
    }

}

