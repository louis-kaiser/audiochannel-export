import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Data Models

struct AudioFileItem: Identifiable {
    let id = UUID()
    let url: URL
    let fileName: String
    let channelCount: Int
    var selectedChannels: Set<Int>
    
    init(url: URL, channelCount: Int) {
        self.url = url
        self.fileName = url.lastPathComponent
        self.channelCount = channelCount
        self.selectedChannels = Set(0..<channelCount)
    }
}

// MARK: - Main View

struct ContentView: View {
    @State private var audioFiles: [AudioFileItem] = []
    @State private var showingImporter = false
    @State private var showingExporter = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var showingError = false
    @State private var successMessage: String?
    @State private var showingSuccess = false
    
    var canExport: Bool {
        !audioFiles.isEmpty && audioFiles.contains { !$0.selectedChannels.isEmpty }
    }
    
    var body: some View {
            VStack(spacing: 0) {
                // Header
                headerView
                
                Divider()
                
                // File List
                if audioFiles.isEmpty {
                    emptyStateView
                } else {
                    fileListView
                }
                
                Divider()
                
                // Bottom toolbar
                bottomToolbar
            }
            .navigationTitle("Audio Channel Extractor")
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [UTType.wav],
                allowsMultipleSelection: true
            ) { result in
                handleFileImport(result: result)
            }
            .alert("Error", isPresented: $showingError, presenting: errorMessage) { _ in
                Button("OK") { errorMessage = nil }
            } message: { message in
                Text(message)
            }
            .alert("Success", isPresented: $showingSuccess, presenting: successMessage) { _ in
                Button("OK") { successMessage = nil }
            } message: { message in
                Text(message)
            }
    }
    
    // MARK: - View Components
    
    private var headerView: some View {
        HStack {
            Text("Imported Files: \(audioFiles.count)")
                .font(.headline)
                .foregroundColor(.secondary)
            
            Spacer()
            
            if !audioFiles.isEmpty {
                Menu {
                    ForEach(0..<(audioFiles.map(\.channelCount).max() ?? 0), id: \.self) { channel in
                        Button("Select Channel \(channel + 1) for All") {
                            selectChannelForAll(channel: channel)
                        }
                    }
                    
                    Divider()
                    
                    Button("Select All Channels for All") {
                        selectAllChannelsForAll()
                    }
                    
                    Button("Deselect All Channels for All") {
                        deselectAllChannelsForAll()
                    }
                } label: {
                    Label("Batch Select", systemImage: "checklist")
                }
                .padding(.trailing, 8)
            }
            
            Button(action: { showingImporter = true }) {
                Label("Import Files", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 80))
                .foregroundColor(.secondary)
            
            Text("No Audio Files Imported")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Click 'Import Files' to select WAV files")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var fileListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(audioFiles.indices, id: \.self) { index in
                    AudioFileCard(
                        file: $audioFiles[index],
                        onRemove: {
                            audioFiles.remove(at: index)
                        }
                    )
                }
            }
            .padding()
        }
    }
    
    private var bottomToolbar: some View {
        HStack {
            Button(action: { audioFiles.removeAll() }) {
                Label("Clear All", systemImage: "trash")
            }
            .disabled(audioFiles.isEmpty)
            
            Spacer()
            
            if isProcessing {
                ProgressView()
                    .padding(.trailing, 8)
                Text("Processing...")
                    .foregroundColor(.secondary)
            }
            
            Button(action: exportChannels) {
                Label("Export Selected Channels", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExport || isProcessing)
        }
        .padding()
    }
    
    // MARK: - File Import Logic
    
    private func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                analyzeAudioFile(url: url)
            }
        case .failure(let error):
            showError("Failed to import files: \(error.localizedDescription)")
        }
    }
    
    private func analyzeAudioFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            showError("Cannot access file: \(url.lastPathComponent)")
            return
        }
        
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let audioFile = try AVAudioFile(forReading: url)
            let channelCount = Int(audioFile.processingFormat.channelCount)
            
            if channelCount == 0 {
                showError("Invalid audio file: \(url.lastPathComponent) has no channels")
                return
            }
            
            let fileItem = AudioFileItem(url: url, channelCount: channelCount)
            audioFiles.append(fileItem)
            
        } catch {
            showError("Cannot read audio file '\(url.lastPathComponent)': \(error.localizedDescription)")
        }
    }
    
    // MARK: - Export Logic
    
    private func exportChannels() {
        isProcessing = true
        
        // Create temporary directory for export
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            var totalExported = 0
            
            for file in audioFiles {
                guard file.url.startAccessingSecurityScopedResource() else {
                    showError("Cannot access file: \(file.fileName)")
                    isProcessing = false
                    return
                }
                
                defer { file.url.stopAccessingSecurityScopedResource() }
                
                for channel in file.selectedChannels.sorted() {
                    do {
                        try extractChannel(from: file.url, channelIndex: channel, to: tempDir, originalName: file.fileName)
                        totalExported += 1
                    } catch {
                        showError("Failed to extract channel \(channel + 1) from '\(file.fileName)': \(error.localizedDescription)")
                        isProcessing = false
                        return
                    }
                }
            }
            
            isProcessing = false
            
            // Show success and save location picker
            saveExportedFiles(from: tempDir, count: totalExported)
            
        } catch {
            showError("Failed to create export directory: \(error.localizedDescription)")
            isProcessing = false
        }
    }
    
    private func extractChannel(from sourceURL: URL, channelIndex: Int, to directory: URL, originalName: String) throws {
        let audioFile = try AVAudioFile(forReading: sourceURL)
        let format = audioFile.processingFormat
        
        // Create mono format
        guard let monoFormat = AVAudioFormat(
            commonFormat: format.commonFormat,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioExtractor", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create mono format"])
        }
        
        // Generate output filename
        let baseName = (originalName as NSString).deletingPathExtension
        let outputName = "\(baseName)_channel_\(channelIndex + 1).wav"
        let outputURL = directory.appendingPathComponent(outputName)
        
        // Create output file
        let outputFile = try AVAudioFile(forWriting: outputURL, settings: monoFormat.settings)
        
        // Process audio in chunks
        let bufferSize: AVAudioFrameCount = 4096
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: bufferSize) else {
            throw NSError(domain: "AudioExtractor", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create buffers"])
        }
        
        audioFile.framePosition = 0
        
        while audioFile.framePosition < audioFile.length {
            let framesToRead = min(bufferSize, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
            
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            
            // Copy selected channel to output
            if let inputChannelData = inputBuffer.floatChannelData,
               let outputChannelData = outputBuffer.floatChannelData {
                
                let channelData = inputChannelData[channelIndex]
                let outputData = outputChannelData[0]
                
                memcpy(outputData, channelData, Int(framesToRead) * MemoryLayout<Float>.size)
                outputBuffer.frameLength = framesToRead
                
                try outputFile.write(from: outputBuffer)
            }
        }
    }
    
    private func saveExportedFiles(from tempDir: URL, count: Int) {
        // For simplicity, we'll show a success message with the temp directory
        // In a full implementation, you'd use a directory picker
        let message = """
        Successfully exported \(count) channel file(s).
        
        Files are saved in: \(tempDir.path)
        
        Please copy them to your desired location.
        """
        
        successMessage = message
        showingSuccess = true
    }
    
    // MARK: - Batch Selection Methods
    
    private func selectChannelForAll(channel: Int) {
        for index in audioFiles.indices {
            if channel < audioFiles[index].channelCount {
                audioFiles[index].selectedChannels.insert(channel)
            }
        }
    }
    
    private func selectAllChannelsForAll() {
        for index in audioFiles.indices {
            audioFiles[index].selectedChannels = Set(0..<audioFiles[index].channelCount)
        }
    }
    
    private func deselectAllChannelsForAll() {
        for index in audioFiles.indices {
            audioFiles[index].selectedChannels.removeAll()
        }
    }
    
    // MARK: - Helper Methods
    
    private func showError(_ message: String) {
        errorMessage = message
        showingError = true
    }
}

// MARK: - Audio File Card View

struct AudioFileCard: View {
    @Binding var file: AudioFileItem
    let onRemove: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(.blue)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.fileName)
                        .font(.headline)
                    
                    Text("\(file.channelCount) channels • \(file.selectedChannels.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            
            Divider()
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(0..<file.channelCount, id: \.self) { channel in
                    HStack {
                        Toggle(isOn: Binding(
                            get: { file.selectedChannels.contains(channel) },
                            set: { isSelected in
                                if isSelected {
                                    file.selectedChannels.insert(channel)
                                } else {
                                    file.selectedChannels.remove(channel)
                                }
                            }
                        )) {
                            Text("Channel \(channel + 1)")
                                .font(.subheadline)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary)
        .cornerRadius(12)
    }
}

// MARK: - App Entry Point

@main
struct AudioChannelExtractorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

