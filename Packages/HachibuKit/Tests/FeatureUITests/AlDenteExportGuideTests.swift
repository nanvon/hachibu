import Foundation
import HistoryStore
import Testing
@testable import FeatureUI

@Suite struct AlDenteExportGuideTests {
    @Test(arguments: ["en", "zh-Hans"])
    func bundledPromptContainsACompleteImportableExample(_ localization: String) throws {
        let prompt = try AlDenteExportGuide.prompt(localization: localization)
        #expect(prompt.hasPrefix(localization == "en" ? "# Export all" : "# 为 Hachibu"))
        let data = try exampleData(in: prompt)
        let archive = try AlDenteArchive(data: data)
        #expect(archive.tables.map(\.table) == AlDenteTable.allCases)
        #expect(archive.tables.allSatisfy { $0.recordCount == 0 })
        #expect(archive.sourceVersion == "EXAMPLE-NOT-AN-EXPORT")
        #expect(archive.recordCount == 0)
    }

    @Test func exampleColumnTypesAcceptCompleteSourceRows() throws {
        let prompt = try AlDenteExportGuide.prompt(localization: "en")
        var root = try #require(JSONSerialization.jsonObject(with: exampleData(in: prompt)) as? [String: Any])
        var tables = try #require(root["tables"] as? [String: [String: Any]])
        for name in Array(tables.keys) {
            var table = try #require(tables[name])
            let columns = try #require(table["columns"] as? [[String: Any]])
            let value: Any
            switch columns[2]["type"] as? String {
            case "INTEGER": value = Int64.max
            case "REAL": value = -48.925483456789
            case "TEXT": value = ""
            default: throw GuideTestError.invalidType
            }
            table["rows"] = [["id": Int64.min, "timestamp": "2026-10-23T00:00:00.000", "value": value]]
            table["rowCount"] = 1
            tables[name] = table
        }
        root["tables"] = tables
        let archive = try AlDenteArchive(data: JSONSerialization.data(withJSONObject: root))
        #expect(archive.recordCount == 13)
        #expect(archive.tables.allSatisfy { $0.recordCount == 1 })
    }

    @Test func defaultLanguageContainsTheSameFormatExample() throws {
        let defaultExample = try exampleData(in: AlDenteExportGuide.prompt())
        let englishExample = try exampleData(in: AlDenteExportGuide.prompt(localization: "en"))
        let chineseExample = try exampleData(in: AlDenteExportGuide.prompt(localization: "zh-Hans"))
        #expect(defaultExample == englishExample)
        #expect(englishExample == chineseExample)
    }
}

private enum GuideTestError: Error {
    case invalidType
}

private func exampleData(in prompt: String) throws -> Data {
    let start = try #require(prompt.range(of: "```json\n", options: .backwards))
    let end = try #require(prompt.range(of: "\n```", range: start.upperBound..<prompt.endIndex))
    return Data(prompt[start.upperBound..<end.lowerBound].utf8)
}
