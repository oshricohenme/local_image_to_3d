import Foundation
import HTTPTypes
import LiftCore
import OpenAPIRuntime

/// The HTTP adapter: one thin handler per openapi.yaml operation. Errors are thrown and become
/// `Problem` responses in `ProblemMiddleware`; gated commands throw `ConfirmationRequired`.
struct API: APIProtocol {
    let lift: Lift
    let server: LiftServer
    var shared: Shared { Shared(lift: lift) }

    // MARK: jobs

    func jobsSubmit(_ input: Operations.JobsSubmit.Input) async throws -> Operations.JobsSubmit.Output {
        let inputs = Inputs(workdir: lift.config.workdir)
        let admission: Admission<JobView>
        switch input.body {
        case .json(let body):
            admission = try await shared.submit(Wire.convert(body), inputs: inputs, source: .http)
        case .multipartForm(let parts):
            var wire: SubmitWire?
            var files: [String: URL] = [:]
            do {
                for try await part in parts {
                    switch part {
                    case .job(let job): wire = try Wire.convert(job.payload.body)
                    case .additionalProperties(let file):
                        let name = file.name ?? ""
                        let url = try inputs.file(part: name, filename: file.filename)
                        let handle = try FileHandle(forWritingTo: url)
                        for try await chunk in file.payload { try handle.write(contentsOf: chunk) }
                        try handle.close()
                        files[name] = url
                    }
                }
            } catch {
                inputs.cleanUp()
                throw error
            }
            guard let wire else {
                inputs.cleanUp()
                throw LiftError.invalidInput([FieldError("job", "required")])
            }
            admission = try await shared.submit(wire, files: files, inputs: inputs, source: .http)
        }
        switch admission {
        case .accepted(let view):
            return .accepted(.init(headers: .init(location: "/v1/jobs/\(view.job.id)"), body: .json(try Wire.convert(JobOut(view)))))
        case .memoryWarning(let warning):
            return .ok(.init(body: .json(try Wire.convert(MemoryWarningOut(memoryWarning: warning)))))
        }
    }

    func jobsList(_ input: Operations.JobsList.Input) async throws -> Operations.JobsList.Output {
        let filter = JobFilter(states: try input.query.state.map { try Wire.convert($0) }, recipe: input.query.recipe,
                               modality: input.query.modality, text: input.query.text)
        return .ok(.init(body: .json(try Wire.convert(JobListOut(jobs: try await lift.jobsList(filter))))))
    }

    func jobsListInterrupted(_ input: Operations.JobsListInterrupted.Input) async throws -> Operations.JobsListInterrupted.Output {
        .ok(.init(body: .json(try Wire.convert(JobListOut(jobs: try await lift.jobsListInterrupted())))))
    }

    func jobsResolveInterrupted(_ input: Operations.JobsResolveInterrupted.Input) async throws -> Operations.JobsResolveInterrupted.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        let action = InterruptedAction(rawValue: body.action.rawValue) ?? .requeue
        return .ok(.init(body: .json(try Wire.convert(JobListOut(jobs: try await lift.jobsResolveInterrupted(ids: body.ids, action: action))))))
    }

    func jobsGet(_ input: Operations.JobsGet.Input) async throws -> Operations.JobsGet.Output {
        .ok(.init(body: .json(try Wire.convert(JobOut(try await lift.jobsGet(input.path.id))))))
    }

    func jobsDelete(_ input: Operations.JobsDelete.Input) async throws -> Operations.JobsDelete.Output {
        let deleted = try gated(await lift.jobsDelete(input.path.id, confirm: input.query.confirm ?? false))
        return .ok(.init(body: .json(.init(deleted: deleted))))
    }

    func jobsWait(_ input: Operations.JobsWait.Input) async throws -> Operations.JobsWait.Output {
        .ok(.init(body: .json(try Wire.convert(JobOut(try await shared.wait(input.path.id, seconds: input.query.timeoutSeconds))))))
    }

    func jobsCancel(_ input: Operations.JobsCancel.Input) async throws -> Operations.JobsCancel.Output {
        .ok(.init(body: .json(try Wire.convert(JobOut(try gated(await lift.jobsCancel(input.path.id, confirm: input.query.confirm ?? false)))))))
    }

    func jobsRetry(_ input: Operations.JobsRetry.Input) async throws -> Operations.JobsRetry.Output {
        var settings: [String: SettingValue]?
        var accept = false
        if case .json(let body) = input.body {
            if let s = body.settings { settings = try Wire.convert(s.additionalProperties) }
            accept = body.acceptMemoryWarning ?? false
        }
        switch try await shared.retry(input.path.id, settings: settings, acceptMemoryWarning: accept) {
        case .accepted(let view): return .accepted(.init(body: .json(try Wire.convert(JobOut(view)))))
        case .memoryWarning(let warning): return .ok(.init(body: .json(try Wire.convert(MemoryWarningOut(memoryWarning: warning)))))
        }
    }

    func jobsMove(_ input: Operations.JobsMove.Input) async throws -> Operations.JobsMove.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        let view = try await shared.move(input.path.id, before: body.before, after: body.after, index: body.index)
        return .ok(.init(body: .json(try Wire.convert(JobOut(view)))))
    }

    func jobsSetPriority(_ input: Operations.JobsSetPriority.Input) async throws -> Operations.JobsSetPriority.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        let view = try await lift.jobsSetPriority(input.path.id, try Wire.convert(body.priority))
        return .ok(.init(body: .json(try Wire.convert(JobOut(view)))))
    }

    func jobsForceStart(_ input: Operations.JobsForceStart.Input) async throws -> Operations.JobsForceStart.Output {
        .ok(.init(body: .json(try Wire.convert(JobOut(try gated(await lift.jobsForceStart(input.path.id, confirm: input.query.confirm ?? false)))))))
    }

    func jobsGetOutput(_ input: Operations.JobsGetOutput.Input) async throws -> Operations.JobsGetOutput.Output {
        let url = try await shared.output(input.path.id, file: input.path.file)
        return .ok(.init(body: .binary(HTTPBody(try Data(contentsOf: url)))))
    }

    // MARK: queue

    func queueStatus(_ input: Operations.QueueStatus.Input) async throws -> Operations.QueueStatus.Output {
        .ok(.init(body: .json(try Wire.convert(QueueOut(try await lift.queueStatus())))))
    }

    func queuePause(_ input: Operations.QueuePause.Input) async throws -> Operations.QueuePause.Output {
        .ok(.init(body: .json(try Wire.convert(QueueOut(try await lift.queuePause())))))
    }

    func queueResume(_ input: Operations.QueueResume.Input) async throws -> Operations.QueueResume.Output {
        .ok(.init(body: .json(try Wire.convert(QueueOut(try await lift.queueResume())))))
    }

    // MARK: models

    func modelsList(_ input: Operations.ModelsList.Input) async throws -> Operations.ModelsList.Output {
        .ok(.init(body: .json(try Wire.convert(ModelListOut(models: try await lift.modelsList())))))
    }

    func modelsGet(_ input: Operations.ModelsGet.Input) async throws -> Operations.ModelsGet.Output {
        .ok(.init(body: .json(try Wire.convert(ModelOut(try await lift.modelsGet(input.path.id))))))
    }

    func modelsUninstall(_ input: Operations.ModelsUninstall.Input) async throws -> Operations.ModelsUninstall.Output {
        let model = try gated(await lift.modelsUninstall(input.path.id, confirm: input.query.confirm ?? false))
        return .ok(.init(body: .json(try Wire.convert(UninstalledOut(model: model)))))
    }

    func modelsInstall(_ input: Operations.ModelsInstall.Input) async throws -> Operations.ModelsInstall.Output {
        let model = try gated(await lift.modelsInstall(input.path.id, confirm: input.query.confirm ?? false, wait: input.query.wait ?? false,
                                                       downloadWeights: input.query.downloadWeights ?? true))
        return .ok(.init(body: .json(try Wire.convert(ModelOut(model)))))
    }

    func modelsReinstall(_ input: Operations.ModelsReinstall.Input) async throws -> Operations.ModelsReinstall.Output {
        let model = try gated(await lift.modelsReinstall(input.path.id, confirm: input.query.confirm ?? false, wait: input.query.wait ?? false))
        return .ok(.init(body: .json(try Wire.convert(ModelOut(model)))))
    }

    func modelsSetPin(_ input: Operations.ModelsSetPin.Input) async throws -> Operations.ModelsSetPin.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        let model = try gated(await lift.modelsSetPin(input.path.id, commit: body.commit, confirm: input.query.confirm ?? false, wait: input.query.wait ?? false))
        return .ok(.init(body: .json(try Wire.convert(ModelOut(model)))))
    }

    func modelsCheckUpstream(_ input: Operations.ModelsCheckUpstream.Input) async throws -> Operations.ModelsCheckUpstream.Output {
        .ok(.init(body: .json(try Wire.convert(try await lift.modelsCheckUpstream(input.path.id)))))
    }

    func modelsInstallLog(_ input: Operations.ModelsInstallLog.Input) async throws -> Operations.ModelsInstallLog.Output {
        .ok(.init(body: .plainText(HTTPBody(try await lift.modelsInstallLog(input.path.id)))))
    }

    func jobsExport(_ input: Operations.JobsExport.Input) async throws -> Operations.JobsExport.Output {
        var formats: [ExportFormat]?
        var dir: String?
        if case .json(let body) = input.body {
            formats = try body.formats.map { try Wire.convert($0) }
            dir = body.dir
        }
        return .ok(.init(body: .json(try Wire.convert(JobOut(try await lift.jobsExport(input.path.id, formats: formats, dir: dir))))))
    }

    func modelsReadme(_ input: Operations.ModelsReadme.Input) async throws -> Operations.ModelsReadme.Output {
        guard let readme = try await lift.modelsReadme(input.path.id) else { throw LiftError.notFound("README for \(input.path.id)") }
        return .ok(.init(body: .json(try Wire.convert(readme))))
    }

    func modelsDownloadWeights(_ input: Operations.ModelsDownloadWeights.Input) async throws -> Operations.ModelsDownloadWeights.Output {
        let model = try gated(await lift.modelsDownloadWeights(input.path.id, confirm: input.query.confirm ?? false, wait: input.query.wait ?? false))
        return .ok(.init(body: .json(try Wire.convert(ModelOut(model)))))
    }

    func downloadsList(_ input: Operations.DownloadsList.Input) async throws -> Operations.DownloadsList.Output {
        .ok(.init(body: .json(try Wire.convert(DownloadListOut(downloads: await lift.downloadsList())))))
    }

    func downloadsPause(_ input: Operations.DownloadsPause.Input) async throws -> Operations.DownloadsPause.Output {
        .ok(.init(body: .json(try Wire.convert(try await lift.downloadsPause(input.path.id)))))
    }

    func downloadsResume(_ input: Operations.DownloadsResume.Input) async throws -> Operations.DownloadsResume.Output {
        .ok(.init(body: .json(try Wire.convert(try await lift.downloadsResume(input.path.id)))))
    }

    func downloadsCancel(_ input: Operations.DownloadsCancel.Input) async throws -> Operations.DownloadsCancel.Output {
        .ok(.init(body: .json(try Wire.convert(try gated(await lift.downloadsCancel(input.path.id, confirm: input.query.confirm ?? false))))))
    }

    func downloadsRetry(_ input: Operations.DownloadsRetry.Input) async throws -> Operations.DownloadsRetry.Output {
        .ok(.init(body: .json(try Wire.convert(try await lift.downloadsRetry(input.path.id)))))
    }

    func downloadsReorder(_ input: Operations.DownloadsReorder.Input) async throws -> Operations.DownloadsReorder.Output {
        .ok(.init(body: .json(try Wire.convert(DownloadListOut(downloads: try await lift.downloadsReorder(input.path.id, position: input.query.position))))))
    }

    func modelsCancelInstall(_ input: Operations.ModelsCancelInstall.Input) async throws -> Operations.ModelsCancelInstall.Output {
        .ok(.init(body: .json(try Wire.convert(ModelOut(try await lift.modelsCancelInstall(input.path.id))))))
    }

    func modelsVerifyWeights(_ input: Operations.ModelsVerifyWeights.Input) async throws -> Operations.ModelsVerifyWeights.Output {
        .ok(.init(body: .json(try Wire.convert(try await lift.modelsVerifyWeights(input.path.id)))))
    }

    // MARK: recipes

    func recipesList(_ input: Operations.RecipesList.Input) async throws -> Operations.RecipesList.Output {
        .ok(.init(body: .json(try Wire.convert(await shared.recipes()))))
    }

    // MARK: workers and resources

    func workersList(_ input: Operations.WorkersList.Input) async throws -> Operations.WorkersList.Output {
        .ok(.init(body: .json(try Wire.convert(WorkerListOut(workers: await lift.workersList())))))
    }

    func workersLoad(_ input: Operations.WorkersLoad.Input) async throws -> Operations.WorkersLoad.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        return .ok(.init(body: .json(try Wire.convert(try await lift.workersLoad(body.recipe)))))
    }

    func workersUnload(_ input: Operations.WorkersUnload.Input) async throws -> Operations.WorkersUnload.Output {
        let workers = try gated(await lift.workersUnload(input.path.id, confirm: input.query.confirm ?? false))
        return .ok(.init(body: .json(try Wire.convert(WorkerListOut(workers: workers)))))
    }

    func resourcesGet(_ input: Operations.ResourcesGet.Input) async throws -> Operations.ResourcesGet.Output {
        .ok(.init(body: .json(try Wire.convert(try await lift.resourcesGet()))))
    }

    func resourcesSet(_ input: Operations.ResourcesSet.Input) async throws -> Operations.ResourcesSet.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        _ = try await lift.resourcesSet(maxSlots: body.maxSlots, memoryBudgetGB: body.memoryBudgetGb, idleUnloadMinutes: body.idleUnloadMinutes)
        return .ok(.init(body: .json(try Wire.convert(await server.settings()))))
    }

    // MARK: settings, server, secrets

    func settingsGet(_ input: Operations.SettingsGet.Input) async throws -> Operations.SettingsGet.Output {
        .ok(.init(body: .json(try Wire.convert(await server.settings()))))
    }

    func settingsSet(_ input: Operations.SettingsSet.Input) async throws -> Operations.SettingsSet.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        return .ok(.init(body: .json(try Wire.convert(try await server.setSetting(body.key.rawValue, try Wire.convert(body.value))))))
    }

    func serverStatus(_ input: Operations.ServerStatus.Input) async throws -> Operations.ServerStatus.Output {
        .ok(.init(body: .json(try Wire.convert(await server.status()))))
    }

    func serverSetLan(_ input: Operations.ServerSetLan.Input) async throws -> Operations.ServerSetLan.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        return .ok(.init(body: .json(try Wire.convert(try gated(await server.setLAN(body.enabled, confirm: input.query.confirm ?? false))))))
    }

    func serverRotateToken(_ input: Operations.ServerRotateToken.Input) async throws -> Operations.ServerRotateToken.Output {
        .ok(.init(body: .json(try Wire.convert(try gated(await server.rotateToken(confirm: input.query.confirm ?? false))))))
    }

    func secretsSetHfToken(_ input: Operations.SecretsSetHfToken.Input) async throws -> Operations.SecretsSetHfToken.Output {
        guard case .json(let body) = input.body else { throw LiftError.invalidInput([FieldError("body", "required")]) }
        return .ok(.init(body: .json(try Wire.convert(try await server.secretsSetHFToken(body.token)))))
    }

    // MARK: system

    func systemPrereqs(_ input: Operations.SystemPrereqs.Input) async throws -> Operations.SystemPrereqs.Output {
        .ok(.init(body: .json(try Wire.convert(await lift.systemPrereqs(checkMetal: input.query.metal ?? false)))))
    }

    func systemInstallPrereqs(_ input: Operations.SystemInstallPrereqs.Input) async throws -> Operations.SystemInstallPrereqs.Output {
        let prereqs = try gated(await lift.systemInstallPrereqs(metal: input.query.metal ?? false, confirm: input.query.confirm ?? false))
        return .ok(.init(body: .json(try Wire.convert(prereqs))))
    }
}

/// The generator writes header values as URI components ("/" becomes "%2F"); `Location` is a path.
struct LocationMiddleware: ServerMiddleware {
    func intercept(_ request: HTTPRequest, body: HTTPBody?, metadata: ServerRequestMetadata, operationID: String,
                   next: @Sendable (HTTPRequest, HTTPBody?, ServerRequestMetadata) async throws -> (HTTPResponse, HTTPBody?))
        async throws -> (HTTPResponse, HTTPBody?) {
        var (response, responseBody) = try await next(request, body, metadata)
        if let location = response.headerFields[.location] { response.headerFields[.location] = location.removingPercentEncoding }
        return (response, responseBody)
    }
}
