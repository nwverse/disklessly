import Foundation

/// A folder where a local AI tool keeps downloaded model weights. They are large, re-downloadable
/// and often forgotten. One list serves both this Mac (`disklessly reconcile`, the usage map) and
/// remote machines (the `model-*` rows of `RemoteScanProbe`).
public struct AIModelLocation: Equatable, Sendable {
    /// Stable id, shared with remote scan rows (`model-hf`, `model-ollama`, ...).
    public let id: String
    public let title: String
    /// Relative to the home folder; the same on macOS and Linux.
    public let relativePath: String
    /// Shown next to the row; the remote probe prints it verbatim.
    public let reason: String
    /// Executable names (basename of the running binary) of the tool that owns the folder. While one
    /// of them runs, the folder is in use and is neither deleted nor offloaded.
    public let processNames: [String]

    public init(id: String, title: String, relativePath: String, reason: String, processNames: [String] = []) {
        self.id = id
        self.title = title
        self.relativePath = relativePath
        self.reason = reason
        self.processNames = processNames
    }

    public func path(home: String) -> String {
        (home.hasSuffix("/") ? home : home + "/") + relativePath
    }
}

public enum AIModelLocations {
    /// Why each row is here:
    /// - Hugging Face Hub: `huggingface_hub` / transformers / diffusers download cache (`HF_HOME` default).
    /// - Ollama: model blobs pulled by `ollama pull`; its server usually runs in the background.
    /// - LM Studio: models folder since 0.3 (`~/.lmstudio/models`); older versions used `~/.cache/lm-studio`.
    /// - PyTorch Hub: `torch.hub` checkpoints (`TORCH_HOME` default `~/.cache/torch`).
    /// - Whisper: `openai-whisper` model downloads (`~/.cache/whisper`).
    public static let all: [AIModelLocation] = [
        AIModelLocation(id: "model-hf", title: "HuggingFace Hub models", relativePath: ".cache/huggingface",
                        reason: "Large AI model weights; can be offloaded to repo or re-downloaded"),
        AIModelLocation(id: "model-ollama", title: "Ollama models", relativePath: ".ollama/models",
                        reason: "Ollama LLM blobs; can be offloaded to repo", processNames: ["ollama", "Ollama"]),
        AIModelLocation(id: "model-lmstudio", title: "LM Studio models", relativePath: ".lmstudio/models",
                        reason: "LM Studio model files; can be offloaded to repo or re-downloaded", processNames: ["LM Studio", "lms"]),
        AIModelLocation(id: "model-lmstudio-legacy", title: "LM Studio models (old location)", relativePath: ".cache/lm-studio",
                        reason: "Models of LM Studio before 0.3; can be offloaded to repo or re-downloaded", processNames: ["LM Studio", "lms"]),
        AIModelLocation(id: "model-torch", title: "PyTorch Hub checkpoints", relativePath: ".cache/torch",
                        reason: "torch.hub model checkpoints; re-downloaded on next use"),
        AIModelLocation(id: "model-whisper", title: "Whisper models", relativePath: ".cache/whisper",
                        reason: "openai-whisper model downloads; re-downloaded on next use"),
    ]

    public static func location(id: String) -> AIModelLocation? { all.first { $0.id == id } }

    /// `probe_dir` lines for the remote scan script (category `model-cache`, action `offload`, recommended).
    public static var remoteProbeLines: String {
        all.map { "probe_dir \"\($0.id)\" \"model-cache\" \"\($0.title)\" \"$HOME/\($0.relativePath)\" \"offload\" \"true\" \"\($0.reason)\"" }
            .joined(separator: "\n") + "\n"
    }
}
