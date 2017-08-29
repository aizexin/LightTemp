import UIKit
import AVFoundation
import Photos
import Foundation

class ViewController: UIViewController, AVCapturePhotoCaptureDelegate {

    @IBOutlet weak var videoPreviewView: VideoPreviewView!

    var captureSession: AVCaptureSession!
    var capturePhotoOutput: AVCapturePhotoOutput!
    var isCaptureSessionConfigured = false
    var photoSampleBuffer: CMSampleBuffer!
    var previewPhotoSampleBuffer: CMSampleBuffer?
    var rawSampleBuffer: CMSampleBuffer!
    var previewRawSampleBuffer: CMSampleBuffer?

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
        if let device = AVCaptureDevice.defaultDevice(withDeviceType: .builtInDualCamera,
                                                      mediaType: AVMediaTypeVideo,
                                                      position: .back) {
            return device // use dual camera on supported devices
        } else if let device = AVCaptureDevice.defaultDevice(withDeviceType: .builtInWideAngleCamera,
                                                             mediaType: AVMediaTypeVideo,
                                                             position: .back) {
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
        self.captureSession.sessionPreset = AVCaptureSessionPresetPhoto
        self.captureSession.addInput(videoInput)
        self.captureSession.addOutput(capturePhotoOutput)
        self.captureSession.commitConfiguration()
        
        self.capturePhotoOutput = capturePhotoOutput
        
        success = true
    }

    func snapPhoto() {
        guard let capturePhotoOutput = self.capturePhotoOutput else { return }
        let videoPreviewLayerOrientation = videoPreviewView.videoPreviewLayer.connection.videoOrientation

        // Update the photo output's connection to match the video orientation of the video preview layer.
        if let photoOutputConnection = capturePhotoOutput.connection(withMediaType: AVMediaTypeVideo) {
            photoOutputConnection.videoOrientation = videoPreviewLayerOrientation
        }

        let photoSettings = createSetting()

        capturePhotoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    func createSetting() -> AVCapturePhotoSettings {
        let availableRawFormatType = capturePhotoOutput.availableRawPhotoPixelFormatTypes.first!

        let photoSettings = AVCapturePhotoSettings(rawPixelFormatType: availableRawFormatType.uint32Value,
                               processedFormat: [AVVideoCodecKey : AVVideoCodecJPEG])

        photoSettings.flashMode = .off

        return photoSettings
    }

    func makeUniqueTempFileURL(typeExtension: String) -> URL {
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).\(typeExtension)")
    }

    func saveRAWPlusJPEGPhotoLibrary(rawSampleBuffer: CMSampleBuffer,
                                     rawPreviewSampleBuffer: CMSampleBuffer?,
                                     photoSampleBuffer: CMSampleBuffer,
                                     previewSampleBuffer: CMSampleBuffer?,
                                     completionHandler: ((_ success: Bool, _ error: Error?) -> Void)?) {
        guard let jpegData = AVCapturePhotoOutput.jpegPhotoDataRepresentation(
            forJPEGSampleBuffer: photoSampleBuffer,
            previewPhotoSampleBuffer: previewSampleBuffer)
            else {
                print("Unable to create JPEG data.")
                completionHandler?(false, nil)
                return
        }

        guard let dngData = AVCapturePhotoOutput.dngPhotoDataRepresentation(
            forRawSampleBuffer: rawSampleBuffer,
            previewPhotoSampleBuffer: rawPreviewSampleBuffer)
            else {
                print("Unable to create DNG data.")
                completionHandler?(false, nil)
                return
        }

        let dngFileURL = self.makeUniqueTempFileURL(typeExtension: "dng")
        do {
            try dngData.write(to: dngFileURL, options: [])
        } catch let error as NSError {
            print("Unable to write DNG file.")
            completionHandler?(false, error)
            return
        }

        let imageFilter = CIFilter(imageURL: dngFileURL, options: nil)
        let temperature = imageFilter?.value(forKey: kCIInputNeutralTemperatureKey)
        print("temperature: \(String(describing: temperature))")

        PHPhotoLibrary.shared().performChanges( {
            let creationRequest = PHAssetCreationRequest.forAsset()
            let creationOptions = PHAssetResourceCreationOptions()
            creationOptions.shouldMoveFile = true
            creationRequest.addResource(with: .photo, data: jpegData, options: nil)
            creationRequest.addResource(with: .alternatePhoto, fileURL: dngFileURL, options: creationOptions)
        }, completionHandler: completionHandler)
    }

    public func capture(_ captureOutput: AVCapturePhotoOutput,
                        didFinishProcessingPhotoSampleBuffer photoSampleBuffer: CMSampleBuffer?,
                        previewPhotoSampleBuffer: CMSampleBuffer?,
                        resolvedSettings: AVCaptureResolvedPhotoSettings,
                        bracketSettings: AVCaptureBracketedStillImageSettings?,
                        error: Error?) {
        guard error == nil, let photoSampleBuffer = photoSampleBuffer else {
            print("Error capturing photo: \(String(describing: error))")
            return
        }

        self.photoSampleBuffer = photoSampleBuffer
        self.previewPhotoSampleBuffer = previewPhotoSampleBuffer
    }

    func capture(_ captureOutput: AVCapturePhotoOutput,
                 didFinishProcessingRawPhotoSampleBuffer rawSampleBuffer: CMSampleBuffer?,
                 previewPhotoSampleBuffer: CMSampleBuffer?,
                 resolvedSettings: AVCaptureResolvedPhotoSettings,
                 bracketSettings: AVCaptureBracketedStillImageSettings?,
                 error: Error?) {
        guard error == nil, let rawSampleBuffer = rawSampleBuffer else {
            print("Error capturing raw photo: \(String(describing: error))")
            return
        }

        self.rawSampleBuffer = rawSampleBuffer
        self.previewRawSampleBuffer = previewPhotoSampleBuffer
    }

    public func capture(_ captureOutput: AVCapturePhotoOutput,
                        didFinishCaptureForResolvedSettings resolvedSettings: AVCaptureResolvedPhotoSettings,
                        error: Error?) {
        guard error == nil else {
            print("Error in capture process: \(String(describing: error))")
            return
        }

        if let rawSampleBuffer = self.rawSampleBuffer, let photoSampleBuffer = self.photoSampleBuffer {
            saveRAWPlusJPEGPhotoLibrary(rawSampleBuffer: rawSampleBuffer,
                                        rawPreviewSampleBuffer: self.previewRawSampleBuffer,
                                        photoSampleBuffer: photoSampleBuffer,
                                        previewSampleBuffer: self.previewPhotoSampleBuffer,
                                        completionHandler: { success, error in
                    if success {
                        print("Added RAW+JPEG photo to library.")
                    } else {
                        print("Error adding RAW+JPEG photo to library: \(String(describing: error))")
                    }
            })
        }
    }

}

