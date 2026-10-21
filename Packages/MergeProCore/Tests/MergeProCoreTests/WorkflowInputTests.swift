import XCTest
@testable import MergeProCore
final class WorkflowInputTests:XCTestCase {
    let yaml="""
    on:
      workflow_dispatch:
        inputs:
          target:
            type: environment
            required: true
          enabled:
            type: boolean
            default: false
          amount:
            type: number
          mode:
            type: choice
            options: [fast, safe]
            default: safe
          token:
            type: string
            description: Secret API token
    """
    func testManualTriggerScalarAndListProduceNoInputForm() throws {
        XCTAssertTrue(try WorkflowInputSchema.parse(yaml:"on: workflow_dispatch",workflowID:2,ref:"main",revision:"sha").inputs.isEmpty)
        XCTAssertTrue(try WorkflowInputSchema.parse(yaml:"on: [push, workflow_dispatch]",workflowID:2,ref:"main",revision:"sha").inputs.isEmpty)
    }
    func testTypedDefaultsAndSecretPresetExclusion() throws {
        let schema=try WorkflowInputSchema.parse(yaml:yaml,workflowID:2,ref:"main",revision:"sha")
        XCTAssertEqual(schema.defaults["enabled"],.boolean(false));XCTAssertEqual(schema.defaults["mode"],.choice("safe"))
        let valid=try schema.validate(["target":.environment("staging"),"amount":.number(2),"token":.text("secret")],environments:["staging"])
        XCTAssertEqual(valid["enabled"],"false")
        XCTAssertEqual(valid["amount"],"2")
        XCTAssertEqual(WorkflowInputValue.number(2.5).string,"2.5")
        let preset=WorkflowPreset(name:"safe",repository:.init(account:.init(host:"github.com",accountID:"1"),repositoryID:"1"),schema:schema,inputs:["token":.text("secret"),"target":.environment("staging")])
        XCTAssertNil(preset.inputs["token"]);XCTAssertFalse(String(decoding:try JSONEncoder.stable.encode(preset),as:UTF8.self).contains("secret"))
    }
    func testChoiceNumberEnvironmentAndRequiredValidation() throws {
        let schema=try WorkflowInputSchema.parse(yaml:yaml,workflowID:2,ref:"main",revision:"sha")
        XCTAssertThrowsError(try schema.validate([:],environments:["staging"]))
        XCTAssertThrowsError(try schema.validate(["target":.environment("other")],environments:["staging"]))
        XCTAssertThrowsError(try schema.validate(["target":.environment("staging"),"mode":.choice("invalid")],environments:["staging"]))
        XCTAssertThrowsError(try schema.validate(["target":.environment("staging"),"amount":.number(.infinity)],environments:["staging"]))
    }
    func testHardcodedAndCustomProductionEnvironmentRequireConfirmation() throws {
        let hardcoded=try WorkflowInputSchema.parse(yaml:"on: workflow_dispatch\njobs:\n  deploy:\n    environment: production",workflowID:2,ref:"main",revision:"sha")
        XCTAssertTrue(hardcoded.requiresProductionConfirmation(values:[:],productionEnvironments:[]))
        let custom=try WorkflowInputSchema.parse(yaml:"on: workflow_dispatch\njobs:\n  deploy:\n    environment:\n      name: release-live",workflowID:2,ref:"main",revision:"sha")
        XCTAssertTrue(custom.requiresProductionConfirmation(values:[:],productionEnvironments:["release-live"]))
        XCTAssertFalse(custom.requiresProductionConfirmation(values:[:],productionEnvironments:[]))
        let dynamic=try WorkflowInputSchema.parse(yaml:"on: workflow_dispatch\njobs:\n  deploy:\n    environment: ${{ matrix.target }}",workflowID:2,ref:"main",revision:"sha")
        XCTAssertTrue(dynamic.requiresProductionConfirmation(values:[:],productionEnvironments:[]))
    }
    func testPinsUseAccountAndRepositoryScopedWorkflowIdentity() {
        let first=RepositoryKey(account:.init(host:"github.com",accountID:"1"),repositoryID:"1")
        let second=RepositoryKey(account:.init(host:"github.com",accountID:"2"),repositoryID:"1")
        var state=ActionsViewState();state.pinnedWorkflows.insert(ActionsViewState.workflowKey(2,repository:first))
        XCTAssertTrue(state.pinnedWorkflows.contains(ActionsViewState.workflowKey(2,repository:first)))
        XCTAssertFalse(state.pinnedWorkflows.contains(ActionsViewState.workflowKey(2,repository:second)))
    }
    func testAggregateRestorationDoesNotOverwriteDistinctAccountViewsAndPins() {
        let a=AccountScope(host:"github.com",accountID:"1"),b=AccountScope(host:"github.com",accountID:"2")
        var first=ActionsViewState();first.filter.branch="a";first.savedViews=[.init(name:"Account A",filter:first.filter)];first.pinnedWorkflows=[ActionsViewState.workflowKey(2,repository:.init(account:a,repositoryID:"1"))]
        var second=ActionsViewState();second.filter.branch="b";second.savedViews=[.init(name:"Account B",filter:second.filter)];second.pinnedWorkflows=[ActionsViewState.workflowKey(2,repository:.init(account:b,repositoryID:"1"))]
        let states=[a:first,b:second],restored=ActionsViewState.aggregate(states)
        XCTAssertEqual(restored.savedViews.count,2);XCTAssertEqual(restored.pinnedWorkflows.count,2)
        XCTAssertEqual(ActionsViewState.distributingEdits(from:restored,to:restored,states:states,newViewsAccount:a),states)
        var edited=restored;edited.savedViews.removeAll { $0.name=="Account A" }
        let distributed=ActionsViewState.distributingEdits(from:restored,to:edited,states:states,newViewsAccount:a)
        XCTAssertEqual(distributed[b],second);XCTAssertEqual(distributed[a]?.savedViews.count,0);XCTAssertEqual(distributed[a]?.filter.branch,"a")
    }
    func testPresetRejectsChangedRevisionAndRef() throws {
        let schema=try WorkflowInputSchema.parse(yaml:yaml,workflowID:2,ref:"main",revision:"sha")
        let preset=WorkflowPreset(name:"safe",repository:.init(account:.init(host:"github.com",accountID:"1"),repositoryID:"1"),schema:schema,inputs:[:])
        XCTAssertTrue(preset.matches(schema));XCTAssertFalse(preset.matches(try .parse(yaml:yaml,workflowID:2,ref:"tag",revision:"sha")))
        XCTAssertFalse(preset.matches(try .parse(yaml:yaml,workflowID:2,ref:"main",revision:"changed")))
    }
}
