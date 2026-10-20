import Foundation
import CryptoKit
import Yams

public enum WorkflowInputValue: Equatable, Codable, Sendable {
    case text(String), choice(String), boolean(Bool), number(Double), environment(String)
    public var string:String {
        switch self { case .text(let v),.choice(let v),.environment(let v):v;case .boolean(let v):v ? "true":"false";case .number(let v):v.rounded() == v && abs(v) < 1e15 ? String(Int64(v)) : String(v) }
    }
}
public struct WorkflowInput: Equatable, Codable, Identifiable, Sendable {
    public enum Kind:String,Codable,Sendable { case string,choice,boolean,number,environment }
    public let id:String
    public let description:String
    public let kind:Kind
    public let required:Bool
    public let options:[String]
    public let defaultValue:WorkflowInputValue?
    public let secret:Bool
}
public struct WorkflowInputSchema: Equatable, Codable, Sendable {
    public let workflowID:Int64
    public let ref:String
    public let revision:String
    public let fingerprint:String
    public let inputs:[WorkflowInput]
    public let environmentTargets:[String]
    public var defaults:[String:WorkflowInputValue] { Dictionary(uniqueKeysWithValues:inputs.compactMap { item in item.defaultValue.map { (item.id,$0) } }) }
    public static func parse(yaml:String,workflowID:Int64,ref:String,revision:String) throws -> Self {
        // YAML's Boolean resolver treats an unquoted `on` as true; Node access preserves its spelling.
        // A quoted `"on":` key is a string-tagged node, so fall back to matching the key's spelling.
        guard let root=try Yams.compose(yaml:yaml),let triggers=root["on"] ?? root.mapping?.first(where:{ $0.key.string == "on" })?.value else { throw ActionsFailure.noManualTrigger }
        let dispatch=triggers["workflow_dispatch"]
        guard dispatch != nil || triggers.string=="workflow_dispatch" || triggers.sequence?.contains(where:{ $0.string=="workflow_dispatch" }) == true else { throw ActionsFailure.noManualTrigger }
        var fields:[WorkflowInput]=[]
        if let mapping=dispatch?["inputs"]?.mapping {
            for (key,node) in mapping {
                guard let id=key.string,!id.isEmpty,let kind=WorkflowInput.Kind(rawValue:node["type"]?.string ?? "string") else { throw ActionsFailure.invalidInput("Unsupported input type") }
                let description=node["description"]?.string ?? ""
                let options=node["options"]?.sequence?.compactMap(\.string) ?? []
                let raw=node["default"].flatMap { $0.null == nil ? $0.scalar?.string : nil } // `null`, `~` or empty means no default
                let value:WorkflowInputValue?
                switch kind {
                case .string:value=raw.map(WorkflowInputValue.text)
                case .choice:guard !options.isEmpty else { throw ActionsFailure.invalidInput(id) };value=raw.map(WorkflowInputValue.choice)
                case .environment:value=raw.map(WorkflowInputValue.environment)
                case .boolean:if let raw { guard ["true","false"].contains(raw.lowercased()) else { throw ActionsFailure.invalidInput(id) };value = .boolean(raw.lowercased()=="true") } else { value=nil }
                case .number:if let raw { guard let number=Double(raw),number.isFinite else { throw ActionsFailure.invalidInput(id) };value = .number(number) } else { value=nil }
                }
                let secretText=(id+" "+description).lowercased()
                let secret=node["secret"]?.bool == true || ["secret","password","token","credential","api_key","private_key"].contains(where:secretText.contains)
                fields.append(.init(id:id,description:description,kind:kind,required:node["required"]?.bool ?? false,options:options,defaultValue:value,secret:secret))
            }
        }
        guard fields.count <= 25,Set(fields.map(\.id)).count == fields.count else { throw ActionsFailure.invalidInput("Too many inputs") }
        let fingerprint=SHA256.hash(data:Data(yaml.utf8)).map { String(format:"%02x",$0) }.joined()
        let targets=root["jobs"]?.mapping?.compactMap { _,job -> String? in job["environment"]?.string ?? job["environment"]?["name"]?.string } ?? []
        return .init(workflowID:workflowID,ref:ref,revision:revision,fingerprint:fingerprint,inputs:fields,environmentTargets:targets)
    }
    func redactingSecrets() -> Self {
        .init(workflowID:workflowID,ref:ref,revision:revision,fingerprint:fingerprint,inputs:inputs.map { input in
            .init(id:input.id,description:input.description,kind:input.kind,required:input.required,options:input.options,defaultValue:input.secret ? nil:input.defaultValue,secret:input.secret)
        },environmentTargets:environmentTargets)
    }
    public func requiresProductionConfirmation(values:[String:WorkflowInputValue],productionEnvironments:Set<String>) -> Bool {
        let values=values.merging(defaults) { supplied,_ in supplied }
        var targets=values.values.compactMap { value -> String? in if case .environment(let name)=value { return name };return nil }
        for expression in environmentTargets {
            if expression.contains("${{") {
                let trimmed=expression.trimmingCharacters(in:.whitespaces)
                let prefix="${{ inputs."
                if trimmed.hasPrefix(prefix),trimmed.hasSuffix("}}") {
                    let key=String(trimmed.dropFirst(prefix.count).dropLast(2)).trimmingCharacters(in:.whitespaces)
                    guard let value=values[key] else { return true };targets.append(value.string)
                } else { return true }
            } else { targets.append(expression) }
        }
        let production=Set(productionEnvironments.map { $0.lowercased() })
        return targets.contains { GitHubActionsProvider.productionName($0) || production.contains($0.lowercased()) }
    }
    public func validate(_ values:[String:WorkflowInputValue],environments:[String]) throws -> [String:String] {
        guard Set(values.keys).isSubset(of:Set(inputs.map(\.id))) else { throw ActionsFailure.invalidInput("Unknown input") }
        var result:[String:String]=[:]
        for field in inputs {
            guard let value=values[field.id] ?? field.defaultValue else { if field.required { throw ActionsFailure.invalidInput(field.id) };continue }
            switch (field.kind,value) {
            case (.string,.text(let text)):if field.required && text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw ActionsFailure.invalidInput(field.id) }
            case (.choice,.choice(let choice)):guard field.options.contains(choice) else { throw ActionsFailure.invalidInput(field.id) }
            case (.boolean,.boolean):break
            case (.number,.number(let number)):guard number.isFinite else { throw ActionsFailure.invalidInput(field.id) }
            case (.environment,.environment(let environment)):guard environments.contains(environment) else { throw ActionsFailure.invalidInput(field.id) }
            default:throw ActionsFailure.invalidInput(field.id)
            }
            result[field.id]=value.string
        }
        return result
    }
}
public struct WorkflowPreset: Equatable, Codable, Identifiable, Sendable {
    public let id:UUID
    public let name:String
    public let repository:RepositoryKey
    public let workflowID:Int64
    public let ref:String
    public let revision:String
    public let fingerprint:String
    public let inputs:[String:WorkflowInputValue]
    public init(name:String,repository:RepositoryKey,schema:WorkflowInputSchema,inputs:[String:WorkflowInputValue],id:UUID=UUID()) {
        self.id=id;self.name=name;self.repository=repository;workflowID=schema.workflowID;ref=schema.ref;revision=schema.revision;fingerprint=schema.fingerprint
        let allowed=Set(schema.inputs.filter { !$0.secret }.map(\.id));self.inputs=inputs.filter { allowed.contains($0.key) }
    }
    public func matches(_ schema:WorkflowInputSchema) -> Bool { workflowID==schema.workflowID && ref==schema.ref && revision==schema.revision && fingerprint==schema.fingerprint }
}
