import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var selectedFiles: [URL] = []
    @State private var channelToExtract: Int = 2
    @State private var isProcessing = false
    @State private var statusMessage = ""
    @State private var showFilePicker = false
    @State private var processedCount = 0
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Audio Channel Extractor")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Extract ONE specific channel from multichannel WAV files")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            // File Selection
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Selected Files:")
                        .font(.headline)
                    Spacer()
                    Button(action: {
                        showFilePicker = true
                    }) {
                        Label("Select Files", systemImage: "folder")
                    }
                }
                
                if selectedFiles.isEmpty {
                    Text("No files selected")
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(selectedFiles, id: \.self) { file in
                                HStack {
                                    Image(systemName: "waveform")
                                        .foregroundColor(.blue)
                                    Text(file.lastPathComponent)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .padding()
                    }
                    .frame(maxHeight: 200)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            
            Divider()
            
            // Channel Selection
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Single Channel to Extract:")
                    .font(.headline)
                
                HStack {
                    Text("Channel Number:")
                    Stepper(value: $channelToExtract, in: 1...32) {
                        Text("\(channelToExtract)")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)
                            .frame(width: 60)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("• Only channel \(channelToExtract) will be exported as mono")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Process Button
            Button(action: processFiles) {
                HStack {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.8)
                    }
                    Text(isProcessing ? "Processing..." : "Extract Channel \(channelToExtract)")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(selectedFiles.isEmpty || isProcessing ? Color.gray : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(selectedFiles.isEmpty || isProcessing)
            
            // Status
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.body)
                    .foregroundColor(statusMessage.contains("Error") ? .red : .green)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding(30)
        .frame(minWidth: 600, minHeight: 500)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.wav, .audio],
            allowsMultipleSelection: true
        ) { result in
            handleFileSelection(result: result)
        }
    }
    
    func handleFileSelection(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            selectedFiles = urls
            statusMessage = "Selected \(urls.count) file(s)"
        case .failure(let error):
            statusMessage = "Error selecting files: \(error.localizedDescription)"
        }
    }
    
    func processFiles() {
        isProcessing = true
        processedCount = 0
        statusMessage = "Processing files..."
        
        Task {
            for fileURL in selectedFiles {
                do {
                    // Start accessing security-scoped resource
                    let accessing = fileURL.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            fileURL.stopAccessingSecurityScopedResource()
                        }
                    }
                    
                    try await extractChannel(from: fileURL, channel: channelToExtract)
                    processedCount += 1
                    
                    await MainActor.run {
                        statusMessage = "Processed \(processedCount) of \(selectedFiles.count) files..."
                    }
                } catch {
                    await MainActor.run {
                        statusMessage = "Error processing \(fileURL.lastPathComponent): \(error.localizedDescription)"
                    }
                }
            }
            
            await MainActor.run {
                isProcessing = false
                statusMessage = "✅ Successfully extracted channel \(channelToExtract) from \(processedCount) file(s)! Saved to Downloads folder."
            }
        }
    }
    
    func extractChannel(from inputURL: URL, channel: Int) async throws {
        let audioFile = try AVAudioFile(forReading: inputURL)
        let format = audioFile.processingFormat
        
        guard channel <= Int(format.channelCount) else {
            throw NSError(domain: "AudioExtractor", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Channel \(channel) does not exist in file (has \(format.channelCount) channels)"])
        }
        
        // Create output format (mono)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: format.sampleRate,
                                        channels: 1,
                                        interleaved: false)!
        
        // Create output file URL
        let fileName = inputURL.deletingPathExtension().lastPathComponent
        let outputFileName = "\(fileName)_channel\(channel).wav"
        let outputURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(outputFileName)
        
        // Remove existing file if present
        try? FileManager.default.removeItem(at: outputURL)
        
        // Create output file
        let outputFile = try AVAudioFile(forWriting: outputURL,
                                         settings: outputFormat.settings,
                                         commonFormat: .pcmFormatFloat32,
                                         interleaved: false)
        
        // Process audio in chunks
        let bufferSize: AVAudioFrameCount = 4096
        let readBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize)!
        let writeBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: bufferSize)!
        
        audioFile.framePosition = 0
        
        while audioFile.framePosition < audioFile.length {
            let framesToRead = min(bufferSize, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
            readBuffer.frameLength = framesToRead
            
            try audioFile.read(into: readBuffer)
            
            // Extract the specified channel (0-indexed)
            if let inputChannelData = readBuffer.floatChannelData,
               let outputChannelData = writeBuffer.floatChannelData {
                let channelIndex = channel - 1 // Convert to 0-indexed
                let frameLength = Int(readBuffer.frameLength)
                
                // Copy data from specified channel to mono output
                memcpy(outputChannelData[0],
                       inputChannelData[channelIndex],
                       frameLength * MemoryLayout<Float>.size)
                
                writeBuffer.frameLength = readBuffer.frameLength
                try outputFile.write(from: writeBuffer)
            }
        }
    }
}

@main
struct AudioChannelExtractorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// Extension to support WAV files
extension UTType {
    static var wav: UTType {
        UTType(filenameExtension: "wav")!
    }
}
