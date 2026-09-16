// TaskHub: a small but real task-tracking service.
//
// This is what a working Espresso application looks like past hello
// world: annotated controllers with constructor injection, model binding
// from route, query and JSON body, validation that answers
// problem+json, API-key authorization with policies, a rate limit on
// the expensive endpoint, request logging on std.log, an HTML dashboard
// rendered server-side from typed models, and OpenAPI for the tools.
//
//   beansc run examples/taskhub/main.b -- --demo     exercise in-memory
//   beansc run examples/taskhub/main.b               serve on :8080
//
// The API:
//   GET    /projects                     list, ?page=&per=
//   POST   /projects                     create             (key)
//   GET    /projects/{id}                one project
//   GET    /projects/{id}/tasks          its tasks, ?status= filter
//   POST   /projects/{id}/tasks          add a task         (key)
//   PATCH  /tasks/{id}                   move status        (key)
//   DELETE /projects/{id}                remove             (admin key)
//   GET    /dashboard                    HTML overview
//   GET    /openapi.json                 the route table
package main

import github.com/beans-lang/barista
import espresso
import std.encoding.json
import std.http
import std.io
import std.log
import std.os
import std.time

// ---- domain ----------------------------------------------------------------

pub class Task {
    pub id: int
    pub title: string
    pub status: string
    pub effort: int

    pub fn init(id: int, move title: string, move status: string,
                effort: int) {
        self.id = id
        self.title = move title
        self.status = move status
        self.effort = effort
    }
}

pub class Project {
    pub id: int
    pub name: string
    pub owner: string
    pub tasks: List<Task>

    pub fn init(id: int, move name: string, move owner: string) {
        self.id = id
        self.name = move name
        self.owner = move owner
        self.tasks = []
    }
}

/// The storage boundary. The in-memory store below is a stand-in with
/// the same surface a database-backed one would have.
pub interface ProjectStore {
    fn all() -> List<Project>
    fn find(id: int) -> Option<Project>
    fn add(move name: string, move owner: string) -> Project
    fn add_task(project: int, move title: string,
                effort: int) -> Option<Task>
    fn move_task(task: int, status: string) -> Option<Task>
    fn remove(id: int) -> bool
}

@barista.service(lifetime: barista.ServiceLifetime.singleton)
pub class MemoryStore implements ProjectStore {
    projects: List<Project>
    next_project: int
    next_task: int

    pub fn init() {
        self.projects = []
        self.next_project = 1
        self.next_task = 1
    }

    pub fn all() -> List<Project> {
        var listed: List<Project> = []
        for project: Project in self.projects {
            listed.push(project)
        }
        return move listed
    }

    pub fn find(id: int) -> Option<Project> {
        for project: Project in self.projects {
            if project.id == id { return some(project) }
        }
        return none
    }

    pub fn add(move name: string, move owner: string) -> Project {
        let made: Project = new Project(
            self.next_project, move name, move owner)
        self.next_project += 1
        self.projects.push(made)
        return made
    }

    pub fn add_task(project: int, move title: string,
                    effort: int) -> Option<Task> {
        match self.find(project) {
            some(found) => {
                let task: Task = new Task(
                    self.next_task, move title, "todo", effort)
                self.next_task += 1
                found.tasks.push(task)
                return some(task)
            }
            none => { return none }
        }
    }

    pub fn move_task(task: int, status: string) -> Option<Task> {
        for project: Project in self.projects {
            for candidate: Task in project.tasks {
                if candidate.id == task {
                    candidate.status = status
                    return some(candidate)
                }
            }
        }
        return none
    }

    pub fn remove(id: int) -> bool {
        for index: int in 0..self.projects.len() {
            if self.projects[index].id == id {
                self.projects.remove(index)
                return true
            }
        }
        return false
    }
}

/// API keys with two levels. A real service would look these up.
@barista.service(lifetime: barista.ServiceLifetime.singleton)
pub class KeyRing implements espresso.Authorizer {
    pub fn init() {}

    pub fn authorize(context: espresso.HttpContext,
                     policy: string) -> Result<bool> {
        let key: string =
            context.request.headers.get("X-Api-Key").or("")
        if policy == "admin" { return ok(key == "admin-key") }
        return ok(key == "writer-key" || key == "admin-key")
    }
}

// ---- wire shapes -----------------------------------------------------------

pub class CreateProject {
    pub name: string
    pub owner: string

    pub fn init(move name: string, move owner: string) {
        self.name = move name
        self.owner = move owner
    }

    pub fn validate(errors: espresso.ValidationErrors) {
        errors.required("name", self.name)
        errors.length("name", self.name, 1, 60)
        errors.required("owner", self.owner)
    }
}

pub class CreateTask {
    pub title: string
    pub effort: int

    pub fn init(move title: string, effort: int) {
        self.title = move title
        self.effort = effort
    }

    pub fn validate(errors: espresso.ValidationErrors) {
        errors.required("title", self.title)
        errors.integer_range("effort", self.effort, 1, 13)
    }
}

pub class MoveTask {
    pub status: string

    pub fn init(move status: string) { self.status = move status }

    pub fn validate(errors: espresso.ValidationErrors) {
        if self.status != "todo" && self.status != "doing" &&
           self.status != "done" {
            errors.add("status", "status must be todo, doing or done",
                       "invalid")
        }
    }
}

struct TaskView {
    id: int
    title: string
    status: string
    effort: int
}

struct ProjectView {
    id: int
    name: string
    owner: string
    open: int
    done: int
    tasks: List<TaskView>
}

struct DashboardView {
    title: string
    projects: List<ProjectView>
}

fn task_view(task: Task) -> TaskView {
    return TaskView {
        id: task.id,
        title: task.title,
        status: task.status,
        effort: task.effort,
    }
}

fn project_view(project: Project) -> ProjectView {
    var open: int = 0
    var done: int = 0
    var tasks: List<TaskView> = []
    for task: Task in project.tasks {
        if task.status == "done" { done += 1 } else { open += 1 }
        tasks.push(task_view(task))
    }
    return ProjectView {
        id: project.id,
        name: project.name,
        owner: project.owner,
        open: open,
        done: done,
        tasks: move tasks,
    }
}

// ---- controllers -----------------------------------------------------------

@espresso.controller(route: "/projects")
pub class ProjectsController extends espresso.Controller {
    store: ProjectStore

    pub fn init(store: ProjectStore) { self.store = store }

    @espresso.get(route: "")
    pub fn list(@espresso.query(default: "1") page: int,
                @espresso.query(default: "10") per: int) ->
        Result<espresso.ActionResult> {
        if page < 1 || per < 1 || per > 100 {
            return self.bad_request("page and per must be positive; per caps at 100")
        }
        let all: List<Project> = self.store.all()
        var views: List<ProjectView> = []
        let start: int = (page - 1) * per
        var index: int = start
        for index < all.len() && index < start + per {
            views.push(project_view(all[index]))
            index += 1
        }
        return self.ok(json.encode(move views)?)
    }

    @espresso.get(route: r"/{id}")
    pub fn show(@espresso.route id: int) ->
        Result<espresso.ActionResult> {
        match self.store.find(id) {
            some(project) => {
                return self.ok(json.encode(project_view(project))?)
            }
            none => { return self.not_found() }
        }
    }

    @espresso.auth
    @espresso.validate
    @espresso.post(route: "")
    pub fn create(@espresso.body move request: CreateProject) ->
        Result<espresso.ActionResult> {
        let made: Project = self.store.add(
            request.name, request.owner)
        return self.created(json.encode(project_view(made))?)
    }

    @espresso.get(route: r"/{id}/tasks")
    pub fn tasks(@espresso.route id: int,
                 @espresso.query(required: false) status: string) ->
        Result<espresso.ActionResult> {
        match self.store.find(id) {
            some(project) => {
                var views: List<TaskView> = []
                for task: Task in project.tasks {
                    if status == "" || task.status == status {
                        views.push(task_view(task))
                    }
                }
                return self.ok(json.encode(move views)?)
            }
            none => { return self.not_found() }
        }
    }

    @espresso.auth
    @espresso.validate
    @espresso.post(route: r"/{id}/tasks")
    pub fn add_task(@espresso.route id: int,
                    @espresso.body move request: CreateTask) ->
        Result<espresso.ActionResult> {
        match self.store.add_task(id, request.title, request.effort) {
            some(task) => {
                return self.created(json.encode(task_view(task))?)
            }
            none => { return self.not_found() }
        }
    }

    @espresso.auth(policy: "admin")
    @espresso.delete(route: r"/{id}")
    pub fn remove(@espresso.route id: int) ->
        Result<espresso.ActionResult> {
        if self.store.remove(id) { return self.no_content() }
        return self.not_found()
    }
}

@espresso.controller(route: "/tasks")
pub class TasksController extends espresso.Controller {
    store: ProjectStore

    pub fn init(store: ProjectStore) { self.store = store }

    @espresso.auth
    @espresso.validate
    @espresso.limit(rpm: 120)
    @espresso.patch(route: r"/{id}")
    pub fn move_task(@espresso.route id: int,
                     @espresso.body move request: MoveTask) ->
        Result<espresso.ActionResult> {
        match self.store.move_task(id, request.status) {
            some(task) => {
                return self.ok(json.encode(task_view(task))?)
            }
            none => { return self.not_found() }
        }
    }
}

@espresso.controller(route: "/dashboard")
pub class DashboardController extends espresso.Controller {
    store: ProjectStore

    pub fn init(store: ProjectStore) { self.store = store }

    @espresso.get(route: "")
    pub fn index() -> Result<espresso.ActionResult> {
        var views: List<ProjectView> = []
        for project: Project in self.store.all() {
            views.push(project_view(project))
        }
        return espresso.view(
            "dashboard",
            DashboardView { title: "TaskHub", projects: move views })
    }
}

// ---- assembly --------------------------------------------------------------

fn dashboard_template() -> string {
    return "<!doctype html><title>\{\{title\}\}</title><h1>\{\{title\}\}</h1>\{\{#projects\}\}<section><h2>#\{\{id\}\} \{\{name\}\} — \{\{owner\}\} (\{\{open\}\} open, \{\{done\}\} done)</h2><ul>\{\{#tasks\}\}<li>[\{\{status\}\}] \{\{title\}\} (\{\{effort\}\})</li>\{\{/tasks\}\}\{\{^tasks\}\}<li>no tasks yet</li>\{\{/tasks\}\}</ul></section>\{\{/projects\}\}\{\{^projects\}\}<p>nothing tracked yet</p>\{\{/projects\}\}"
}

fn build_app(logger: log.Logger) -> Result<espresso.WebApplication> {
    let builder: espresso.WebApplicationBuilder =
        new espresso.WebApplicationBuilder()
    espresso.add_services(builder)?
    let views: espresso.Views = new espresso.Views()
    views.add("dashboard", dashboard_template())?
    espresso.add_views(builder, views)?
    espresso.add_controllers(builder)?

    let app: espresso.WebApplication = builder.build()?
    app.use_middleware(new espresso.RequestLog(logger))?
    app.use(espresso.security_headers)?
    espresso.map_controllers(app)?
    espresso.map_openapi(app, "/openapi.json", "TaskHub", "1.0.0")?
    return ok(app)
}

fn seed(app: espresso.WebApplication) -> Result<bool> {
    let host: espresso.TestHost = new espresso.TestHost(app)
    let headers_json: Result<espresso.TestResponse> = seed_request(
        host, "POST", "/projects",
        "\{\"name\":\"Espresso 0.2\",\"owner\":\"ada\"\}")
    headers_json?
    seed_request(host, "POST", "/projects",
        "\{\"name\":\"Beans 1.0 bake\",\"owner\":\"lin\"\}")?
    seed_request(host, "POST", "/projects/1/tasks",
        "\{\"title\":\"ship ActionResult\",\"effort\":5\}")?
    seed_request(host, "POST", "/projects/1/tasks",
        "\{\"title\":\"write the docs\",\"effort\":3\}")?
    seed_request(host, "PATCH", "/tasks/1",
        "\{\"status\":\"done\"\}")?
    return ok(true)
}

fn seed_request(host: espresso.TestHost, method: string,
                target: string,
                body: string) -> Result<espresso.TestResponse> {
    let headers: http.Headers = new http.Headers()
    headers.add("X-Api-Key", "admin-key")
    headers.add("Content-Type", "application/json")
    return host.send_with_headers(method, target, headers, body)
}

fn demo(app: espresso.WebApplication) -> Result<bool> {
    let host: espresso.TestHost = new espresso.TestHost(app)
    io.println("projects {host.get("/projects")?.text()}")
    io.println("one {host.get("/projects/1")?.text()}")
    io.println("tasks {host.get("/projects/1/tasks?status=todo")?.text()}")
    io.println("missing {host.get("/projects/99")?.status}")
    io.println("unauthorized {host.post("/projects", "\{\}")?.status}")
    let dashboard: espresso.TestResponse = host.get("/dashboard")?
    io.println("dashboard {dashboard.status} {dashboard.text().len()} bytes")
    return ok(true)
}

fn main() {
    let logger: log.Logger =
        espresso.console_logger("taskhub").expect("logger")
    let app: espresso.WebApplication =
        build_app(logger).expect("app")
    seed(app).expect("seed")

    let arguments: List<string> = os.args()
    if arguments.contains("--demo") {
        demo(app).expect("demo")
        app.close().expect("close")
        return
    }

    let options: espresso.ServerOptions = new espresso.ServerOptions()
    options.port = 8080
    let server: espresso.WebServer =
        espresso.WebServer.bind(app, options).expect("bind")
    io.println("TaskHub on http://127.0.0.1:{server.port().expect("port")}")
    io.println("dashboard at /dashboard, spec at /openapi.json")
    server.run().expect("run")
}
