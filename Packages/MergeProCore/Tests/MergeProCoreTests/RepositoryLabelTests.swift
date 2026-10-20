import XCTest
@testable import MergeProCore

/// Stateful label provider: REST create, GraphQL catalog reads and GraphQL update/delete by node ID.
private actor LabelFixture:GitHubTransport {
    struct Label { var id:String;var name:String;var color:String;var description:String?;var open:Int }
    var labels:[Label]=[Label(id:"L1",name:"Bug",color:"D73A4A",description:"Something broken",open:3),Label(id:"L2",name:"area/ui",color:"0E8A16",description:nil,open:0)]
    var permission="WRITE"
    var push=true
    var endlessPages=false
    var lost=false
    var dropWrite=false
    var graphQLWriteBody:String?
    var restStatus:Int?
    var requests:[URLRequest]=[]
    var catalogReads=0
    var writes=0
    func configure(permission:String="WRITE",push:Bool=true,endlessPages:Bool=false,lost:Bool=false,dropWrite:Bool=false,graphQLWriteBody:String?=nil,restStatus:Int?=nil) { self.permission=permission;self.push=push;self.endlessPages=endlessPages;self.lost=lost;self.dropWrite=dropWrite;self.graphQLWriteBody=graphQLWriteBody;self.restStatus=restStatus }
    func paths() -> [String] { requests.map { $0.url!.absoluteString } }
    func setLabels(_ value:[Label]) { labels=value }
    /// REST label writes by name, as raw percent-encoded request paths.
    func restWrites() -> [String] { requests.filter { ["PATCH","DELETE"].contains($0.httpMethod ?? "") }.map { ($0.httpMethod ?? "")+" "+$0.url!.path(percentEncoded:true) } }
    func graphQLMutations() -> Int { requests.filter { $0.url!.path=="/graphql" && String(decoding:$0.httpBody ?? Data(),as:UTF8.self).contains("mutation") }.count }
    func send(_ request:URLRequest) async throws -> GitHubResponse {
        requests.append(request)
        let path=request.url!.path
        if path=="/graphql" {
            let envelope=try JSONSerialization.jsonObject(with:request.httpBody ?? Data()) as! [String:Any]
            let query=envelope["query"] as! String,variables=envelope["variables"] as? [String:Any] ?? [:]
            if query.hasPrefix("mutation") {
                writes+=1
                let input=variables["input"] as! [String:Any],id=input["id"] as! String
                if let graphQLWriteBody { return .init(status:200,data:Data(graphQLWriteBody.utf8)) }
                if !dropWrite {
                    if query.contains("deleteLabel") { labels.removeAll { $0.id==id } }
                    else if let index=labels.firstIndex(where:{ $0.id==id }) { labels[index].name=input["name"] as! String;labels[index].color=input["color"] as! String;labels[index].description=input["description"] as? String }
                }
                if lost { throw URLError(.networkConnectionLost) }
                if query.contains("deleteLabel") { return .init(status:200,data:Data("{\"data\":{\"deleteLabel\":{\"clientMutationId\":null}}}".utf8)) }
                let label=labels.first { $0.id==id }!
                return .init(status:200,data:Data("{\"data\":{\"updateLabel\":{\"label\":{\"id\":\"\(label.id)\",\"name\":\"\(label.name)\",\"color\":\"\(label.color)\",\"description\":\"\(label.description ?? "")\",\"isDefault\":false}}}}".utf8))
            }
            catalogReads+=1
            let after=variables["after"] as? String
            if endlessPages {
                let page=Int(after ?? "0")!
                let nodes=(0..<100).map { "{\"id\":\"P\(page)-\($0)\",\"name\":\"p\(page)-\($0)\",\"color\":\"ffffff\",\"description\":null,\"isDefault\":false,\"pullRequests\":{\"totalCount\":0}}" }.joined(separator:",")
                return .init(status:200,data:Data("{\"data\":{\"repository\":{\"id\":\"R_1\",\"databaseId\":1,\"viewerPermission\":\"\(permission)\",\"labels\":{\"nodes\":[\(nodes)],\"pageInfo\":{\"hasNextPage\":true,\"endCursor\":\"\(page+1)\"}}}}}".utf8))
            }
            let nodes=labels.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"color\":\"\($0.color)\",\"description\":\($0.description.map { "\"\($0)\"" } ?? "null"),\"isDefault\":\($0.id=="L1"),\"pullRequests\":{\"totalCount\":\($0.open)}}" }.joined(separator:",")
            return .init(status:200,data:Data("{\"data\":{\"repository\":{\"id\":\"R_1\",\"databaseId\":1,\"viewerPermission\":\"\(permission)\",\"labels\":{\"nodes\":[\(nodes)],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}".utf8))
        }
        if ["PATCH","DELETE"].contains(request.httpMethod ?? ""),path.hasPrefix("/repos/o/r/labels/") {
            writes+=1
            let name=String(path.dropFirst("/repos/o/r/labels/".count))
            if let restStatus { return .init(status:restStatus,data:Data("{\"message\":\"Refused\"}".utf8)) }
            guard let index=labels.firstIndex(where:{ $0.name.lowercased()==name.lowercased() }) else { return .init(status:404,data:Data("{\"message\":\"Not Found\"}".utf8)) }
            if request.httpMethod=="DELETE" { if !dropWrite { labels.remove(at:index) };if lost { throw URLError(.networkConnectionLost) };return .init(status:204) }
            let body=try JSONSerialization.jsonObject(with:request.httpBody ?? Data()) as! [String:Any]
            if !dropWrite { labels[index].name=body["new_name"] as? String ?? labels[index].name;labels[index].color=body["color"] as? String ?? labels[index].color;labels[index].description=(body["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
            if lost { throw URLError(.networkConnectionLost) }
            let label=labels[index]
            return .init(status:200,data:try JSONSerialization.data(withJSONObject:["id":7,"node_id":label.id,"name":label.name,"color":label.color,"description":label.description.map { $0 as Any } ?? NSNull(),"default":false]))
        }
        if request.httpMethod=="POST",path=="/repos/o/r/labels" {
            writes+=1
            let body=try JSONSerialization.jsonObject(with:request.httpBody ?? Data()) as! [String:Any]
            let name=body["name"] as! String,color=body["color"] as! String
            if labels.contains(where:{ $0.name.lowercased()==name.lowercased() }) { return .init(status:422,data:Data("{\"message\":\"Validation Failed\",\"errors\":[{\"resource\":\"Label\",\"code\":\"already_exists\",\"field\":\"name\"}]}".utf8)) }
            if !dropWrite { labels.append(Label(id:"L\(labels.count+10)",name:name,color:color,description:body["description"] as? String,open:0)) }
            if lost { throw URLError(.networkConnectionLost) }
            return .init(status:201,data:Data("{\"id\":99,\"node_id\":\"L\(labels.count+9)\",\"name\":\"\(name)\",\"color\":\"\(color)\",\"description\":null,\"default\":false}".utf8))
        }
        return .init(status:200,data:Data("{\"id\":1,\"permissions\":{\"push\":\(push),\"triage\":\(push)},\"default_branch\":\"main\"}".utf8))
    }
}

@MainActor final class RepositoryLabelTests:XCTestCase {
    let repository=RepoCatalogEntry(repository:Repository(key:RepositoryKey(account:AccountScope(host:"github.com",accountID:"42"),repositoryID:"1"),name:"o/r",isPrivate:true,capabilities:[]),accountLogin:"actor")
    private func fixture(_ transport:LabelFixture) throws -> (DatabaseStore,RepositoryBrowserService) {
        let fixture=try makeSessionFixture(account:repository.key.account,repositories:[repository.repository],transport:transport)
        return (fixture.database,RepositoryBrowserService(session:fixture.session,budget:RateBudget(minimumSpacing:.zero),database:fixture.database,clientID:"fixture",activeAccount:fixture.activeAccount))
    }

    func testCatalogParsesLabelsOpenCountsAndManagePermission() async throws {
        let transport=LabelFixture();let (_,service)=try fixture(transport)
        let catalog=try await service.labels(repository)
        XCTAssertEqual(catalog.repositoryNodeID,"R_1");XCTAssertTrue(catalog.complete);XCTAssertTrue(catalog.canManage)
        XCTAssertEqual(catalog.labels,[RepositoryLabel(id:"L1",name:"Bug",color:"d73a4a",description:"Something broken",isDefault:true,openPullRequests:3),RepositoryLabel(id:"L2",name:"area/ui",color:"0e8a16",description:nil,isDefault:false,openPullRequests:0)])
        let cached=try await service.cachedLabels(repository)
        XCTAssertEqual(cached?.labels,catalog.labels)
        await transport.configure(permission:"TRIAGE")
        let triage=try await service.labels(repository);XCTAssertTrue(triage.canManage)
        await transport.configure(permission:"READ")
        let reader=try await service.labels(repository);XCTAssertFalse(reader.canManage)
    }
    func testCatalogPaginationIsBoundedAndMarkedIncomplete() async throws {
        let transport=LabelFixture();await transport.configure(endlessPages:true)
        let (_,service)=try fixture(transport)
        let catalog=try await service.labels(repository)
        XCTAssertFalse(catalog.complete);XCTAssertEqual(catalog.labels.count,3000)
        let reads=await transport.catalogReads;XCTAssertEqual(reads,30)
    }
    func testColorNormalizationNameValidationAndLuminance() {
        XCTAssertEqual(RepositoryLabel.normalizedColor("#FFAA00"),"ffaa00")
        XCTAssertEqual(RepositoryLabel.normalizedColor(" 0E8A16 "),"0e8a16")
        for invalid in ["fa0","#12345","gggggg","1234567",""] { XCTAssertNil(RepositoryLabel.normalizedColor(invalid),invalid) }
        XCTAssertTrue(RepositoryLabel.validName(" area/ui "));XCTAssertTrue(RepositoryLabel.validName(String(repeating:"x",count:50)))
        for invalid in ["","   ",String(repeating:"x",count:51),"a\nb"] { XCTAssertFalse(RepositoryLabel.validName(invalid),invalid) }
        XCTAssertTrue(RepositoryLabel.prefersDarkText(hex:"ffffff"));XCTAssertTrue(RepositoryLabel.prefersDarkText(hex:"#FFFF00"));XCTAssertTrue(RepositoryLabel.prefersDarkText(hex:"c2e0c6"))
        XCTAssertFalse(RepositoryLabel.prefersDarkText(hex:"000000"));XCTAssertFalse(RepositoryLabel.prefersDarkText(hex:"0000ff"));XCTAssertFalse(RepositoryLabel.prefersDarkText(hex:"5319e7"))
    }
    func testLedgerIdentitiesAreDeterministic() {
        let key=repository.key
        XCTAssertEqual(RepositoryLabelMutation.create(name:"Area/UI",color:"ffffff",description:nil).identity(repository:key),"label-create|1|area/ui")
        XCTAssertEqual(RepositoryLabelMutation.update(id:"L2",name:"x",color:"ffffff",description:nil).identity(repository:key),"label-update|1|L2")
        XCTAssertEqual(RepositoryLabelMutation.delete(id:"L2",name:"x").identity(repository:key),"label-delete|1|L2")
    }
    func testCreatePostsNormalizedLabelAndUpdatesCache() async throws {
        let transport=LabelFixture();let (_,service)=try fixture(transport)
        let created=try await service.apply(.create(name:" docs ",color:"#C2E0C6",description:"Docs"),to:repository)
        XCTAssertEqual(created?.name,"docs");XCTAssertEqual(created?.color,"c2e0c6")
        let posted=await transport.requests.first { $0.httpMethod=="POST" && $0.url!.path=="/repos/o/r/labels" }
        let body=try JSONSerialization.jsonObject(with:posted!.httpBody!) as! [String:Any]
        XCTAssertEqual(body["name"] as? String,"docs");XCTAssertEqual(body["color"] as? String,"c2e0c6")
        let cached=try await service.cachedLabels(repository)
        XCTAssertTrue(cached?.labels.contains { $0.name=="docs" } == true)
    }
    func testDuplicateCreateIsRejectedBeforeAnyPost() async throws {
        let transport=LabelFixture();let (_,service)=try fixture(transport)
        do { _ = try await service.apply(.create(name:"bug",color:"ffffff",description:nil),to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryLabelFailure,.existingLabel) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
        let pending=try await service.pendingLabelMutations(repository);XCTAssertTrue(pending.isEmpty)
    }
    func testRenameOntoAnotherLabelIsRejectedCaseInsensitively() async throws {
        let transport=LabelFixture();let (_,service)=try fixture(transport)
        do { _ = try await service.apply(.update(id:"L2",name:"BUG",color:"ffffff",description:nil),to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryLabelFailure,.existingLabel) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testUpdateAndDeleteUseGraphQLNodeIDsNotNamePaths() async throws {
        let transport=LabelFixture();let (_,service)=try fixture(transport)
        let updated=try await service.apply(.update(id:"L2",name:"area/ux",color:"FBCA04",description:"Interface"),to:repository)
        XCTAssertEqual(updated,RepositoryLabel(id:"L2",name:"area/ux",color:"fbca04",description:"Interface",isDefault:false,openPullRequests:nil))
        let deleted=try await service.apply(.delete(id:"L2",name:"area/ux"),to:repository)
        XCTAssertNil(deleted)
        let paths=await transport.paths();XCTAssertFalse(paths.contains { $0.contains("area") })
        let mutations=await transport.requests.filter { $0.url!.path=="/graphql" && String(decoding:$0.httpBody ?? Data(),as:UTF8.self).contains("mutation") }
        XCTAssertEqual(mutations.count,2)
        XCTAssertTrue(String(decoding:mutations[0].httpBody!,as:UTF8.self).contains("updateLabel"));XCTAssertTrue(String(decoding:mutations[1].httpBody!,as:UTF8.self).contains("deleteLabel"))
        let remaining=await transport.labels.map(\.id);XCTAssertEqual(remaining,["L1"])
    }
    func testWithoutManagePermissionNothingIsSent() async throws {
        let transport=LabelFixture();await transport.configure(push:false)
        let (_,service)=try fixture(transport)
        do { _ = try await service.apply(.delete(id:"L2",name:"area/ui"),to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.permissionDenied) }
        let writes=await transport.writes;XCTAssertEqual(writes,0)
    }
    func testLostCreateResponseReconcilesAppliedWithoutResending() async throws {
        let transport=LabelFixture();await transport.configure(lost:true)
        let (_,service)=try fixture(transport)
        let mutation=RepositoryLabelMutation.create(name:"docs",color:"c2e0c6",description:nil)
        do { _ = try await service.apply(mutation,to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let pending=try await service.pendingLabelMutations(repository);XCTAssertEqual(pending,[mutation])
        do { _ = try await service.apply(mutation,to:repository);XCTFail("an unknown write must never be repeated") } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let result=try await service.reconcileLabel(mutation,in:repository)
        XCTAssertEqual(result,.applied)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
        let after=try await service.pendingLabelMutations(repository);XCTAssertTrue(after.isEmpty)
    }
    func testLostDeleteThatNeverAppliedReconcilesNotAppliedWithoutResending() async throws {
        let transport=LabelFixture();await transport.configure(lost:true,dropWrite:true)
        let (_,service)=try fixture(transport)
        let mutation=RepositoryLabelMutation.delete(id:"L2",name:"area/ui")
        do { _ = try await service.apply(mutation,to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let result=try await service.reconcileLabel(mutation,in:repository)
        XCTAssertEqual(result,.notApplied)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
        let after=try await service.pendingLabelMutations(repository);XCTAssertTrue(after.isEmpty)
    }
    func testGraphQLDenialIsARejectionNotAnUnknownOutcome() async throws {
        let transport=LabelFixture();await transport.configure(graphQLWriteBody:"{\"data\":{\"updateLabel\":null},\"errors\":[{\"type\":\"FORBIDDEN\",\"message\":\"Resource not accessible by integration\"}]}")
        let (_,service)=try fixture(transport)
        do { _ = try await service.apply(.update(id:"L2",name:"area/ux",color:"ffffff",description:nil),to:repository);XCTFail() } catch { XCTAssertEqual((error as? GitHubGraphQLMutationFailure)?.definitelyRejected,true) }
        let pending=try await service.pendingLabelMutations(repository);XCTAssertTrue(pending.isEmpty)
    }
    static let schemaRejection="{\"errors\":[{\"path\":[\"mutation UpdateLabel\",\"updateLabel\"],\"extensions\":{\"code\":\"undefinedField\",\"typeName\":\"Mutation\",\"fieldName\":\"updateLabel\"},\"message\":\"Field 'updateLabel' doesn't exist on type 'Mutation'\"}]}"
    /// A definite GraphQL schema rejection applied nothing, so the same ledger identity falls back to REST.
    func testSchemaRejectedUpdateFallsBackToRESTPatchByEncodedCurrentName() async throws {
        let transport=LabelFixture();await transport.configure(graphQLWriteBody:Self.schemaRejection)
        let (db,service)=try fixture(transport)
        let updated=try await service.apply(.update(id:"L2",name:"area/ux",color:"FBCA04",description:"Interface"),to:repository)
        XCTAssertEqual(updated,RepositoryLabel(id:"L2",name:"area/ux",color:"fbca04",description:"Interface",isDefault:false,openPullRequests:nil))
        let rest=await transport.restWrites();XCTAssertEqual(rest,["PATCH /repos/o/r/labels/area%2Fui"],"The CURRENT name, as one encoded segment")
        let patch=await transport.requests.first { $0.httpMethod=="PATCH" }
        let body=try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(patch?.httpBody)) as? [String:Any])
        XCTAssertEqual(body["new_name"] as? String,"area/ux");XCTAssertEqual(body["color"] as? String,"fbca04");XCTAssertEqual(body["description"] as? String,"Interface")
        let mutations=await transport.graphQLMutations();XCTAssertEqual(mutations,1)
        XCTAssertEqual(try RepositoryBrowserPersistence(database:db).operationState("label-update|1|L2",account:repository.key.account),"applied","One ledger identity covers both attempts")
        let pending=try await service.pendingLabelMutations(repository);XCTAssertTrue(pending.isEmpty)
        let cached=try await service.cachedLabels(repository);XCTAssertEqual(cached?.labels.first { $0.id=="L2" }?.name,"area/ux")
    }
    func testSchemaRejectedDeleteFallsBackToRESTDelete() async throws {
        let transport=LabelFixture();await transport.configure(graphQLWriteBody:Self.schemaRejection.replacingOccurrences(of:"updateLabel",with:"deleteLabel"))
        let (db,service)=try fixture(transport)
        let deleted=try await service.apply(.delete(id:"L2",name:"stale display name"),to:repository);XCTAssertNil(deleted)
        let rest=await transport.restWrites();XCTAssertEqual(rest,["DELETE /repos/o/r/labels/area%2Fui"])
        let remaining=await transport.labels.map(\.id);XCTAssertEqual(remaining,["L1"])
        XCTAssertEqual(try RepositoryBrowserPersistence(database:db).operationState("label-delete|1|L2",account:repository.key.account),"applied")
    }
    func testRESTFallbackEncodesEveryLabelNameAsOneSegment() async throws {
        let expected:[(String,String)]=[("area/ui","area%2Fui"),("priority: high","priority%3A%20high"),("a?b","a%3Fb"),("100%","100%25"),("c++","c%2B%2B"),("über","%C3%BCber"),("a#b","a%23b"),("v1.0~x","v1.0~x")]
        for (name,segment) in expected { XCTAssertEqual(RepositoryBrowserService.labelPathSegment(name),segment,name) }
        for dots in [".",".."] { XCTAssertNil(RepositoryBrowserService.labelPathSegment(dots),"A dot segment could be normalized into another resource") }
        let transport=LabelFixture();await transport.configure(graphQLWriteBody:Self.schemaRejection)
        await transport.setLabels(expected.enumerated().map { .init(id:"N\($0.offset)",name:$0.element.0,color:"ffffff",description:nil,open:0) })
        let (_,service)=try fixture(transport)
        for (index,(name,_)) in expected.enumerated() { _ = try await service.apply(.update(id:"N\(index)",name:name,color:"000000",description:nil),to:repository) }
        let rest=await transport.restWrites();XCTAssertEqual(rest,expected.map { "PATCH /repos/o/r/labels/"+$0.1 })
    }
    func testNoRESTFallbackAfterADefiniteNonSchemaDenial() async throws {
        let transport=LabelFixture();await transport.configure(graphQLWriteBody:"{\"data\":{\"deleteLabel\":null},\"errors\":[{\"type\":\"FORBIDDEN\",\"message\":\"Resource not accessible by integration\"}]}")
        let (_,service)=try fixture(transport)
        do { _ = try await service.apply(.delete(id:"L2",name:"area/ui"),to:repository);XCTFail() } catch { XCTAssertEqual((error as? GitHubGraphQLMutationFailure)?.definitelyRejected,true) }
        let rest=await transport.restWrites();XCTAssertTrue(rest.isEmpty)
    }
    func testNoRESTFallbackAfterAnAmbiguousGraphQLOutcome() async throws {
        for body in [nil,"{\"data\":null,\"errors\":[{\"message\":\"Something went wrong while executing your query.\"}]}"] {
            let transport=LabelFixture();await transport.configure(lost:body == nil,dropWrite:true,graphQLWriteBody:body)
            let (_,service)=try fixture(transport)
            let mutation=RepositoryLabelMutation.update(id:"L2",name:"area/ux",color:"ffffff",description:nil)
            do { _ = try await service.apply(mutation,to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
            let rest=await transport.restWrites();XCTAssertTrue(rest.isEmpty,"A possibly applied GraphQL write is never followed by a REST resend")
            let writes=await transport.writes;XCTAssertEqual(writes,1)
            let pending=try await service.pendingLabelMutations(repository);XCTAssertEqual(pending,[mutation])
        }
    }
    func testSchemaRejectionWithoutAProvenCurrentNameStaysUnavailable() async throws {
        let transport=LabelFixture();await transport.configure(endlessPages:true,graphQLWriteBody:Self.schemaRejection)
        let (_,service)=try fixture(transport)
        do { _ = try await service.apply(.update(id:"L2",name:"area/ux",color:"ffffff",description:nil),to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryLabelFailure,.labelEditingUnavailable) }
        let rest=await transport.restWrites();XCTAssertTrue(rest.isEmpty)
        let pending=try await service.pendingLabelMutations(repository);XCTAssertTrue(pending.isEmpty)
    }
    func testRESTFallbackRefusalIsARejectionNotAnUnknownOutcome() async throws {
        let transport=LabelFixture();await transport.configure(graphQLWriteBody:Self.schemaRejection,restStatus:422)
        let (_,service)=try fixture(transport)
        do { _ = try await service.apply(.update(id:"L2",name:"area/ux",color:"ffffff",description:nil),to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryLabelFailure,.invalidLabel) }
        let pending=try await service.pendingLabelMutations(repository);XCTAssertTrue(pending.isEmpty)
    }
    /// Outdated pending writes settle against a COMPLETE catalog instead of throwing forever.
    func testReconcileSettlesAnUpdateOfALabelDeletedSinceAsNotApplied() async throws {
        let transport=LabelFixture();await transport.configure(lost:true,dropWrite:true)
        let (_,service)=try fixture(transport)
        let mutation=RepositoryLabelMutation.update(id:"L2",name:"area/ux",color:"ffffff",description:nil)
        do { _ = try await service.apply(mutation,to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        await transport.setLabels([.init(id:"L1",name:"Bug",color:"D73A4A",description:nil,open:0)])
        let result=try await service.reconcileLabel(mutation,in:repository);XCTAssertEqual(result,.notApplied)
        let after=try await service.pendingLabelMutations(repository);XCTAssertTrue(after.isEmpty)
        let writes=await transport.writes;XCTAssertEqual(writes,1)
    }
    func testReconcileSettlesACreateWhoseNameExistsWithAnotherColorAsApplied() async throws {
        let transport=LabelFixture();await transport.configure(lost:true,dropWrite:true)
        let (_,service)=try fixture(transport)
        let mutation=RepositoryLabelMutation.create(name:"docs",color:"c2e0c6",description:nil)
        do { _ = try await service.apply(mutation,to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let current=await transport.labels;await transport.setLabels(current+[.init(id:"L9",name:"Docs",color:"000000",description:nil,open:0)])
        let result=try await service.reconcileLabel(mutation,in:repository);XCTAssertEqual(result,.applied,"The name exists, so the create's intent is satisfied")
        let after=try await service.pendingLabelMutations(repository);XCTAssertTrue(after.isEmpty)
    }
    func testReconcileMatchesACreateByReceiptNodeIDBeforeName() async throws {
        let transport=LabelFixture();let (db,service)=try fixture(transport)
        let mutation=RepositoryLabelMutation.create(name:"docs",color:"c2e0c6",description:nil)
        try RepositoryBrowserPersistence(database:db).record(mutation.identity(repository:repository.key),account:repository.key.account,state:"unknown",data:Data("{\"node_id\":\"L9\",\"name\":\"docs\",\"color\":\"c2e0c6\"}".utf8))
        let current=await transport.labels;await transport.setLabels(current+[.init(id:"L9",name:"documentation",color:"c2e0c6",description:nil,open:0)])
        let result=try await service.reconcileLabel(mutation,in:repository);XCTAssertEqual(result,.applied,"Renamed since, but the receipt's node proves the create applied")
    }
    func testReconcileKeepsOutdatedWritesPendingWhenTheCatalogIsIncomplete() async throws {
        let transport=LabelFixture();await transport.configure(lost:true,dropWrite:true)
        let (_,service)=try fixture(transport)
        let mutation=RepositoryLabelMutation.update(id:"L2",name:"area/ux",color:"ffffff",description:nil)
        do { _ = try await service.apply(mutation,to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        await transport.configure(endlessPages:true)
        do { _ = try await service.reconcileLabel(mutation,in:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let pending=try await service.pendingLabelMutations(repository);XCTAssertEqual(pending,[mutation])
    }
    func testUnclassifiedGraphQLErrorRemainsUnknown() async throws {
        let transport=LabelFixture();await transport.configure(graphQLWriteBody:"{\"data\":null,\"errors\":[{\"message\":\"Something went wrong while executing your query.\"}]}")
        let (_,service)=try fixture(transport)
        let mutation=RepositoryLabelMutation.delete(id:"L2",name:"area/ui")
        do { _ = try await service.apply(mutation,to:repository);XCTFail() } catch { XCTAssertEqual(error as? RepositoryBrowserFailure,.unknownWriteOutcome) }
        let pending=try await service.pendingLabelMutations(repository);XCTAssertEqual(pending,[mutation])
    }
}
