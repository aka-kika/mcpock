import Foundation

/// Which glyph a server row shows.
enum ServerIcon: Equatable, Sendable {
    /// A template image in the asset catalog ("server-github").
    case asset(String)
    /// An SF Symbol ("folder").
    case symbol(String)
    /// No icon known: the mcpock mark.
    case fallback
    /// Her own picture for this server, a file in `ServerIcons.userDirectory`
    /// (the path). Drawn in one colour, like the rest.
    case file(String)
}

/// Picks a glyph for a server from its name, package or host.
/// The brand glyphs are Simple Icons (CC0-1.0); the rest are SF Symbols.
/// Brand marks belong to their owners; mcpock is not affiliated with them.
enum ServerIcons {
    struct Entry: Sendable {
        let icon: ServerIcon
        let names: [String]
        let packages: [String]
        let hosts: [String]
    }

    private static func a(_ slug: String) -> ServerIcon { .asset("server-" + slug) }
    private static func s(_ name: String) -> ServerIcon { .symbol(name) }

    /// One line per server. Add new servers here.
    static let table: [Entry] = [
        Entry(icon: a("upstash"), names: ["context7"], packages: ["@upstash/context7-mcp"], hosts: ["mcp.context7.com"]),
        Entry(icon: s("folder"), names: ["filesystem"], packages: ["@modelcontextprotocol/server-filesystem"], hosts: []),
        Entry(icon: s("theatermasks"), names: ["playwright"], packages: ["@playwright/mcp", "@executeautomation/playwright-mcp-server"], hosts: []),
        Entry(icon: a("github"), names: ["github"], packages: ["@modelcontextprotocol/server-github"], hosts: ["api.githubcopilot.com"]),
        Entry(icon: a("googlechrome"), names: ["chrome-devtools"], packages: ["chrome-devtools-mcp"], hosts: []),
        Entry(icon: s("arrow.down.circle"), names: ["fetch"], packages: ["mcp-server-fetch"], hosts: []),
        Entry(icon: s("brain"), names: ["memory"], packages: ["@modelcontextprotocol/server-memory"], hosts: []),
        Entry(icon: s("list.number"), names: ["sequential-thinking", "sequentialthinking"], packages: ["@modelcontextprotocol/server-sequential-thinking"], hosts: []),
        Entry(icon: a("git"), names: ["git", "git-mcp"], packages: ["mcp-server-git"], hosts: []),
        Entry(icon: s("clock"), names: ["time"], packages: ["mcp-server-time"], hosts: []),
        Entry(icon: s("square.grid.2x2"), names: ["everything"], packages: ["@modelcontextprotocol/server-everything"], hosts: []),
        Entry(icon: a("sqlite"), names: ["sqlite"], packages: ["mcp-server-sqlite"], hosts: []),
        Entry(icon: a("puppeteer"), names: ["puppeteer"], packages: ["@modelcontextprotocol/server-puppeteer"], hosts: []),
        Entry(icon: a("postgresql"), names: ["postgres", "postgresql"], packages: ["@modelcontextprotocol/server-postgres"], hosts: []),
        Entry(icon: a("brave"), names: ["brave-search", "brave"], packages: ["@brave/brave-search-mcp-server", "@modelcontextprotocol/server-brave-search"], hosts: []),
        Entry(icon: a("notion"), names: ["notion"], packages: ["@notionhq/notion-mcp-server"], hosts: ["mcp.notion.com"]),
        Entry(icon: a("figma"), names: ["figma"], packages: ["figma-developer-mcp"], hosts: ["mcp.figma.com"]),
        Entry(icon: s("terminal"), names: ["desktop-commander"], packages: ["@wonderwhy-er/desktop-commander"], hosts: []),
        Entry(icon: s("flame"), names: ["firecrawl"], packages: ["firecrawl-mcp"], hosts: ["mcp.firecrawl.dev"]),
        Entry(icon: s("magnifyingglass"), names: ["exa"], packages: ["exa-mcp-server"], hosts: ["mcp.exa.ai"]),
        Entry(icon: s("checklist"), names: ["task-master", "taskmaster"], packages: ["task-master-ai"], hosts: []),
        Entry(icon: s("wand.and.rays"), names: ["magic"], packages: ["@21st-dev/magic"], hosts: []),
        Entry(icon: a("cloudflare"), names: ["cloudflare"], packages: ["@cloudflare/mcp-server-cloudflare"], hosts: ["mcp.cloudflare.com", "docs.mcp.cloudflare.com", "observability.mcp.cloudflare.com", "bindings.mcp.cloudflare.com"]),
        Entry(icon: a("grafana"), names: ["grafana"], packages: [], hosts: ["mcp.grafana.com"]),
        Entry(icon: s("macwindow"), names: ["browserbase"], packages: ["@browserbasehq/mcp-server-browserbase"], hosts: []),
        Entry(icon: s("doc.text"), names: ["markdownify"], packages: [], hosts: []),
        Entry(icon: a("supabase"), names: ["supabase"], packages: ["@supabase/mcp-server-supabase"], hosts: ["mcp.supabase.com"]),
        Entry(icon: s("magnifyingglass"), names: ["tavily"], packages: ["tavily-mcp"], hosts: []),
        Entry(icon: a("mysql"), names: ["mysql"], packages: ["@benborla29/mcp-server-mysql"], hosts: []),
        Entry(icon: a("kubernetes"), names: ["kubernetes"], packages: ["kubernetes-mcp-server", "mcp-server-kubernetes"], hosts: []),
        Entry(icon: a("stripe"), names: ["stripe"], packages: ["@stripe/mcp"], hosts: ["mcp.stripe.com"]),
        Entry(icon: a("terraform"), names: ["terraform"], packages: [], hosts: []),
        Entry(icon: a("mongodb"), names: ["mongodb"], packages: ["mongodb-mcp-server"], hosts: []),
        Entry(icon: a("sentry"), names: ["sentry"], packages: ["@sentry/mcp-server", "mcp-server-sentry"], hosts: ["mcp.sentry.dev"]),
        Entry(icon: a("linear"), names: ["linear"], packages: [], hosts: ["mcp.linear.app"]),
        Entry(icon: a("atlassian"), names: ["atlassian"], packages: [], hosts: ["mcp.atlassian.com"]),
        Entry(icon: a("vercel"), names: ["vercel"], packages: ["next-devtools-mcp"], hosts: ["mcp.vercel.com"]),
        Entry(icon: a("zapier"), names: ["zapier"], packages: [], hosts: ["mcp.zapier.com"]),
        Entry(icon: a("perplexity"), names: ["perplexity"], packages: ["@perplexity-ai/mcp-server"], hosts: []),
        Entry(icon: a("paypal"), names: ["paypal"], packages: ["@paypal/mcp"], hosts: []),
        Entry(icon: a("neon"), names: ["neon"], packages: ["@neondatabase/mcp-server-neon"], hosts: ["mcp.neon.tech"]),
        Entry(icon: a("redis"), names: ["redis"], packages: ["redis-mcp-server", "@modelcontextprotocol/server-redis"], hosts: []),
        Entry(icon: a("clickhouse"), names: ["clickhouse"], packages: ["mcp-clickhouse"], hosts: []),
        Entry(icon: a("upstash"), names: ["upstash"], packages: ["@upstash/mcp-server", "@upstash/redis-mcp"], hosts: ["mcp.upstash.com"]),
        Entry(icon: a("planetscale"), names: ["planetscale"], packages: [], hosts: ["mcp.pscale.dev"]),
        Entry(icon: a("posthog"), names: ["posthog"], packages: [], hosts: ["mcp.posthog.com"]),
        Entry(icon: a("airtable"), names: ["airtable"], packages: [], hosts: ["mcp.airtable.com"]),
        Entry(icon: a("webflow"), names: ["webflow"], packages: [], hosts: ["mcp.webflow.com"]),
        Entry(icon: s("chart.bar"), names: ["amplitude"], packages: [], hosts: ["mcp.amplitude.com", "mcp.eu.amplitude.com"]),
        Entry(icon: a("circleci"), names: ["circleci"], packages: [], hosts: ["mcp.circleci.com"]),
        Entry(icon: a("clerk"), names: ["clerk"], packages: [], hosts: ["mcp.clerk.com"]),
        Entry(icon: a("auth0"), names: ["auth0"], packages: ["@auth0/auth0-mcp-server"], hosts: []),
        Entry(icon: a("postman"), names: ["postman"], packages: ["@postman/postman-mcp-server"], hosts: []),
        Entry(icon: a("mintlify"), names: ["mintlify"], packages: [], hosts: ["mcp.mintlify.com"]),
        Entry(icon: a("gitlab"), names: ["gitlab"], packages: ["@modelcontextprotocol/server-gitlab"], hosts: ["gitlab.com"]),
        Entry(icon: a("zoom"), names: ["zoom"], packages: [], hosts: ["mcp.zoom.us"]),
        Entry(icon: a("digitalocean"), names: ["digitalocean"], packages: [], hosts: ["mcp.digitalocean.com"]),
        Entry(icon: a("pagerduty"), names: ["pagerduty"], packages: ["pagerduty-mcp"], hosts: []),
        Entry(icon: a("neo4j"), names: ["neo4j"], packages: ["mcp-neo4j-cypher", "mcp-neo4j-memory"], hosts: []),
        Entry(icon: a("obsidian"), names: ["obsidian"], packages: ["obsidian-mcp-server"], hosts: []),
        Entry(icon: a("googledrive"), names: ["google-drive", "gdrive"], packages: ["@modelcontextprotocol/server-gdrive"], hosts: []),
        Entry(icon: a("googlemaps"), names: ["google-maps"], packages: ["@modelcontextprotocol/server-google-maps"], hosts: []),
        Entry(icon: a("gmail"), names: ["gmail"], packages: [], hosts: []),
        Entry(icon: a("googlesheets"), names: ["google-sheets"], packages: [], hosts: []),
        Entry(icon: a("googlecalendar"), names: ["google-calendar"], packages: [], hosts: []),
        Entry(icon: a("googlebigquery"), names: ["bigquery"], packages: [], hosts: []),
        Entry(icon: s("paintbrush"), names: ["everart"], packages: ["@modelcontextprotocol/server-everart"], hosts: []),
        Entry(icon: a("pubmed"), names: ["pubmed"], packages: [], hosts: []),
        Entry(icon: a("n8n"), names: ["n8n"], packages: [], hosts: []),
        Entry(icon: a("docker"), names: ["docker"], packages: [], hosts: []),
        Entry(icon: a("hubspot"), names: ["hubspot"], packages: [], hosts: []),
        Entry(icon: a("shopify"), names: ["shopify"], packages: [], hosts: []),
        Entry(icon: a("datadog"), names: ["datadog"], packages: [], hosts: []),
        Entry(icon: a("snowflake"), names: ["snowflake"], packages: [], hosts: []),
        Entry(icon: a("elasticsearch"), names: ["elasticsearch"], packages: [], hosts: []),
        Entry(icon: a("asana"), names: ["asana"], packages: [], hosts: []),
        Entry(icon: a("discord"), names: ["discord"], packages: [], hosts: []),
        Entry(icon: a("dropbox"), names: ["dropbox"], packages: [], hosts: []),
        Entry(icon: a("youtube"), names: ["youtube"], packages: [], hosts: []),
        Entry(icon: a("whatsapp"), names: ["whatsapp"], packages: [], hosts: []),
        Entry(icon: a("reddit"), names: ["reddit"], packages: [], hosts: []),
        Entry(icon: a("monday"), names: ["monday", "monday-com"], packages: ["@mondaydotcomorg/monday-api-mcp"], hosts: ["mcp.monday.com"]),
        Entry(icon: s("square.3.layers.3d"), names: ["icon-composer", "iconcomposer"], packages: [], hosts: []),
    ]

    /// Ordered, first hit wins. A keyword matches a whole `-` part of the name.
    static let keywords: [(word: String, icon: ServerIcon)] = [
        ("notes", .symbol("note.text")),
        ("mail", .symbol("envelope")),
        ("obsidian", .asset("server-obsidian")),
        ("safari", .asset("server-safari")),
        ("xcode", .asset("server-xcode")),
        ("xcodebuildmcp", .asset("server-xcode")),
        ("youtube", .asset("server-youtube")),
        ("chrome", .asset("server-googlechrome")),
        ("claude", .asset("server-claude")),
        ("shopify", .asset("server-shopify")),
        ("github", .asset("server-github")),
        ("apple", .asset("server-apple")),
        ("hig", .asset("server-apple")),
        ("calendar", .symbol("calendar")),
        ("eventkit", .symbol("calendar")),
        ("memory", .symbol("brain")),
        ("manual", .symbol("book")),
        ("docs", .symbol("book")),
        ("search", .symbol("magnifyingglass")),
        ("screen", .symbol("camera.viewfinder")),
        ("fetch", .symbol("arrow.down.circle")),
        ("files", .symbol("folder")),
        ("filesystem", .symbol("folder")),
        ("time", .symbol("clock")),
        ("feed", .symbol("newspaper")),
        ("photo", .symbol("photo")),
        ("photos", .symbol("photo")),
        ("icon", .symbol("square.on.square")),
        ("automator", .symbol("gearshape.2")),
        ("macos", .symbol("macwindow")),
        ("md", .symbol("doc.text")),
        ("markdown", .symbol("doc.text")),
        ("board", .symbol("list.bullet.rectangle")),
        ("social", .symbol("at")),
        ("socials", .symbol("at")),
        ("skill", .symbol("books.vertical")),
        ("librarian", .symbol("books.vertical")),
        ("container", .symbol("shippingbox")),
        ("containeruse", .symbol("shippingbox")),
    ]

    /// The table by name, built once: as written, and normalized (review
    /// 22 Nov: every row of every draw walked and normalized the whole table).
    private static let byName: [String: ServerIcon] = {
        var out: [String: ServerIcon] = [:]
        for e in table { for n in e.names where out[n] == nil { out[n] = e.icon } }
        return out
    }()

    private static let byNormalizedName: [String: ServerIcon] = {
        var out: [String: ServerIcon] = [:]
        for e in table { for n in e.names.map(normalize) where out[n] == nil { out[n] = e.icon } }
        return out
    }()

    private static let cacheLock = NSLock()
    private static var cache: [String: ServerIcon] = [:]

    // MARK: Your own icons (22 Nov)

    /// `~/Library/Application Support/mcpock/ServerIcons/`: one picture per
    /// server, named like the server (`my-server.svg`, `.pdf` or `.png`),
    /// shown in one colour in place of whatever the table says. For servers
    /// the table can't know (her own apps, a company's own server); the
    /// files stay on her Mac. Read only, never written.
    static var defaultUserDirectory: URL {
        MCPockStatus.defaultDirectory().appendingPathComponent("ServerIcons", isDirectory: true)
    }

    /// Where own icons are read from; nil (the start value, and in demo mode
    /// and hosted tests) reads nothing, so a demo picture never shows one.
    static var userDirectory: URL? {
        get { userLock.lock(); defer { userLock.unlock() }; return userFolder }
        set { userLock.lock(); userFolder = newValue; userIndex = [:]; userRead = nil; userLock.unlock() }
    }

    static let userFileTypes: Set<String> = ["svg", "pdf", "png"]
    private static let userLock = NSLock()
    private static var userFolder: URL?
    private static var userIndex: [String: String] = [:]
    private static var userRead: Date?

    /// The name a file and a server meet on: lowercased, the mcp/server
    /// decoration dropped, letters and digits only ("Safari_MCP" is "safari").
    static func userKey(_ name: String) -> String {
        normalize(name).filter { $0.isLetter || $0.isNumber }
    }

    /// Her own picture for `name`, if the folder has one. The folder is
    /// listed again at most every three seconds.
    static func userIcon(name: String, now: Date = Date()) -> ServerIcon? {
        userLock.lock()
        defer { userLock.unlock() }
        guard let folder = userFolder else { return nil }
        if userRead.map({ now.timeIntervalSince($0) > 3 || now < $0 }) ?? true {
            var index: [String: String] = [:]
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files.sorted() where userFileTypes.contains((file as NSString).pathExtension.lowercased()) {
                let key = userKey((file as NSString).deletingPathExtension)
                if !key.isEmpty, index[key] == nil { index[key] = folder.appendingPathComponent(file).path }
            }
            userIndex = index
            userRead = now
        }
        return userIndex[userKey(name)].map(ServerIcon.file)
    }

    /// `targets` are the command lines or URLs from the config. The answer
    /// for a name and its targets never changes, so it is kept.
    static func icon(name: String, targets: [String]) -> ServerIcon {
        if let own = userIcon(name: name) { return own }
        let key = name + "\u{1F}" + targets.joined(separator: "\u{1F}")
        cacheLock.lock()
        if let found = cache[key] {
            cacheLock.unlock()
            return found
        }
        cacheLock.unlock()
        let found = lookUp(name: name, targets: targets)
        cacheLock.lock()
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = found
        cacheLock.unlock()
        return found
    }

    /// Pure: the lookup itself.
    static func lookUp(name: String, targets: [String]) -> ServerIcon {
        let lower = name.lowercased()
        let normalized = normalize(lower)

        // a. Name: exact, then normalized.
        if let icon = byName[lower] { return icon }
        if let icon = byNormalizedName[normalized] { return icon }

        // b. Package as a whole token of a command line.
        let tokens = targets.flatMap { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        for e in table {
            for p in e.packages where tokens.contains(where: { tokenMatches($0, package: p) }) {
                return e.icon
            }
        }

        // c. URL host: equal to, or a subdomain of, a table host.
        let hosts = targets.compactMap { host(of: $0) }
        for e in table {
            for h in e.hosts where hosts.contains(where: { $0 == h || $0.hasSuffix("." + h) }) {
                return e.icon
            }
        }

        // d. Keywords on whole name parts.
        let parts = Set(normalized.split(separator: "-").map(String.init))
        for k in keywords where parts.contains(k.word) { return k.icon }

        return .fallback
    }

    static func icon(for group: ServerGroup) -> ServerIcon {
        icon(name: group.name, targets: group.sources.map(\.target))
    }

    // MARK: helpers

    /// Lowercase, `_` and spaces become `-`, then drop the mcp/server decoration.
    private static func normalize(_ raw: String) -> String {
        var n = raw.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        for suffix in ["-mcp-server", "-mcp", "-server"] where n.hasSuffix(suffix) && n.count > suffix.count {
            n.removeLast(suffix.count)
            break
        }
        for prefix in ["mcp-", "server-"] where n.hasPrefix(prefix) && n.count > prefix.count {
            n.removeFirst(prefix.count)
            break
        }
        return n
    }

    /// The token is the package, or the package with an `@version` suffix.
    private static func tokenMatches(_ token: String, package: String) -> Bool {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if t == package { return true }
        return t.hasPrefix(package + "@")
    }

    private static func host(of target: String) -> String? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("http://") || t.hasPrefix("https://"),
              let h = URL(string: t)?.host?.lowercased() else { return nil }
        return h
    }
}
