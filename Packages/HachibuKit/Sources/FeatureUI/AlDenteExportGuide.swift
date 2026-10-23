import Foundation

/// 随应用提供的导出任务说明；复制内容包含完整格式示例，不依赖远程文档。
enum AlDenteExportGuide {
    enum ResourceError: Error {
        case missingResource
    }

    static func prompt(localization: String? = nil) throws -> String {
        let language = localization ?? Bundle.module.preferredLocalizations.first ?? "en"
        guard let instructionsURL = Bundle.module.url(
            forResource: "AlDenteExportPrompt", withExtension: "md",
            subdirectory: nil, localization: language
        ) ?? Bundle.module.url(
            forResource: "AlDenteExportPrompt", withExtension: "md",
            subdirectory: nil, localization: "en"
        ), let exampleURL = Bundle.module.url(forResource: "AlDenteExportExample", withExtension: "json")
        else { throw ResourceError.missingResource }
        let instructions = try String(contentsOf: instructionsURL, encoding: .utf8)
        let example = try String(contentsOf: exampleURL, encoding: .utf8)
        return instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n\n```json\n" + example.trimmingCharacters(in: .whitespacesAndNewlines) + "\n```\n"
    }
}
