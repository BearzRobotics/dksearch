//! The text of `dksearch --help`, `dksearch help COMMAND` and
//! `dksearch COMMAND --help`. Kept apart from the command code so that it can
//! be read, reviewed and tested as text. The manual page (docs/manpages) has
//! the full reference; this is what a person needs at the terminal.

const std = @import("std");

pub const Command = struct {
    name: []const u8,
    /// The synopsis line(s), without the leading "dksearch ".
    synopsis: []const u8,
    /// One line for the overview.
    summary: []const u8,
    /// Everything else `dksearch help NAME` shows.
    detail: []const u8,
};

pub const commands = [_]Command{
    .{
        .name = "serve",
        .synopsis = "serve [--config FILE]",
        .summary = "Run the search website and API (and the admin interface, if set up)",
        .detail =
        \\Starts the public search interface: a search page at http://ADDRESS:PORT/ and a
        \\JSON API under /api/v1/ (see `man dksearch-api`). The address and port come from
        \\the [server] table of the configuration file (default 127.0.0.1:8080).
        \\
        \\If the file has an [admin] table and an admin credential exists, the
        \\administration interface starts too, on its own address and port (default
        \\127.0.0.1:8081). See `dksearch help admin` for how to set that up.
        \\
        \\Searching works while imports run. Stop it with Ctrl-C; running requests finish first.
        \\
        ,
    },
    .{
        .name = "import",
        .synopsis = "import --config FILE (SOURCE | --all) [--prune]",
        .summary = "Read or fetch a source and add its documents to the index",
        .detail =
        \\SOURCE is the name of a [[source]] table in the configuration file; --all runs
        \\every enabled source. An interrupted import resumes where it stopped, and
        \\documents that did not change are skipped.
        \\
        \\--prune also removes the source's documents that are no longer in the source,
        \\after a run that completed (only some connectors can tell, see the manual).
        \\
        \\Example: dksearch import --config dksearch.toml my-notes
        \\
        ,
    },
    .{
        .name = "remove",
        .synopsis = "remove --config FILE SOURCE [--yes]",
        .summary = "Delete all documents a source imported",
        .detail =
        \\Removes every document imported under the name SOURCE from the index, the stored
        \\text and the records, and forgets its import history. Nothing is removed unless
        \\you add --yes. SOURCE need not still be in the configuration file.
        \\
        ,
    },
    .{
        .name = "models",
        .synopsis = "models list | pull NAME --yes | remove NAME --yes  [--config FILE]",
        .summary = "List, download or delete the models of the local Ollama",
        .detail =
        \\Talks to the Ollama server at [ollama] url (default http://127.0.0.1:11434). `list`
        \\shows the models it has. `pull NAME` downloads a model (often 1 to 10 GB) and `remove
        \\NAME` deletes one: both change what is on disk, so they only run with --yes. dksearch
        \\never starts Ollama and never pulls anything by itself. Use a model for semantic search
        \\with [embeddings] (api = "ollama") and for written answers with [answers].
        \\
        ,
    },
    .{
        .name = "node-key",
        .synopsis = "node-key [--config FILE]",
        .summary = "Make this node's identity (a key pair) and print its node id",
        .detail =
        \\Makes an Ed25519 key pair in data_dir/node-identity.toml (mode 0600) if the node has
        \\none, and prints the node id (dkn_ and 43 characters). Running it again only prints
        \\the id. The id is public: give it to the owners of peers that should recognise this
        \\node, so they can bind an API key to it (`api-key add NAME ... --node ID`) or pin it
        \\in a [[peer]] (`node = "ID"`). The file is secret. Restart `serve` to use it: requests
        \\to peers are then signed, and answers to callers that ask are signed.
        \\
        ,
    },
    .{
        .name = "embed",
        .synopsis = "embed [--config FILE]",
        .summary = "Make the vectors for semantic search (needs [embeddings])",
        .detail =
        \\Asks the embedding model server named in [embeddings] (Ollama, or any server with
        \\an OpenAI-style /v1/embeddings) for a vector for each stored document and keeps
        \\them in data_dir/vectors.db. Documents that already have one for the model are
        \\skipped, so it can be stopped and run again, and run again after an import. Nothing
        \\here starts a model: run the server yourself. Search then takes `semantic=1`.
        \\
        ,
    },
    .{
        .name = "rebuild",
        .synopsis = "rebuild [--config FILE]",
        .summary = "Recreate the search index from the stored text",
        .detail =
        \\Deletes the index and builds it again from the stored text and records, without
        \\reading any source. Use it after losing index.db, after a version change, or
        \\after changing [index] tokenizer. Stop `serve` first if searches must be complete.
        \\
        ,
    },
    .{
        .name = "check",
        .synopsis = "check [--config FILE]",
        .summary = "Check the stored data for damage (read-only)",
        .detail =
        \\Verifies the three databases and every stored text against its record. Prints
        \\one line per database, then `ok` (exit status 0) or `problem:` (exit status 1).
        \\
        ,
    },
    .{
        .name = "backup",
        .synopsis = "backup [--config FILE] DIR",
        .summary = "Write a verified copy of the stored data into DIR",
        .detail =
        \\Copies state.db and content.db (the only copies of what was imported) into DIR,
        \\which must not already hold them. Safe while `serve` or `import` runs. The index
        \\is not copied; `restore` or `rebuild` recreates it.
        \\
        ,
    },
    .{
        .name = "restore",
        .synopsis = "restore [--config FILE] [--no-index] DIR",
        .summary = "Recreate the stored data from a backup made by `backup`",
        .detail =
        \\Checks the backup in DIR, writes state.db and content.db into data_dir (never
        \\overwriting: move old files away first) and rebuilds the index, unless you give
        \\--no-index. Stop `serve` first.
        \\
        ,
    },
    .{
        .name = "admin-token",
        .synopsis = "admin-token [--config FILE]",
        .summary = "Create the admin API token (printed once)",
        .detail =
        \\Creates a new random token for the administration interface and API, prints it
        \\ONCE on standard output, and stores only a hash of it. Running it again replaces
        \\the token; the old one stops working at once. Send it as
        \\    Authorization: Bearer TOKEN
        \\The token alone (no password) is enough to use the admin API with curl.
        \\See `dksearch help admin` for the whole setup.
        \\
        ,
    },
    .{
        .name = "api-key",
        .synopsis = "api-key add NAME (--all | --collection NAME ...) [--rate PER_MINUTE] [--node ID] | list | remove NAME_OR_ID  [--config FILE]",
        .summary = "Make, list or remove API keys that limit what a caller can see",
        .detail =
        \\An API key lets a program (or another dksearch) use the search API and see only
        \\the collections it was made for. Collections are groups of sources, written as
        \\[[collection]] tables in the configuration.
        \\
        \\    dksearch api-key add laptop --collection books --collection docs
        \\    dksearch api-key add backup --all
        \\    dksearch api-key add public --collection books --rate 60   # at most 60 requests a minute
        \\    dksearch api-key list
        \\    dksearch api-key remove laptop
        \\
        \\`add` prints the key ONCE and stores only its hash in data_dir/api-keys.toml. Send
        \\it as `Authorization: Bearer KEY`. A key that is added or removed works or stops
        \\within a second on a running server. To require a key for everything, put
        \\`[access] anonymous_collections = []` in the configuration.
        \\
        ,
    },
    .{
        .name = "admin-password",
        .synopsis = "admin-password [--config FILE]",
        .summary = "Set the admin password for signing in with a browser",
        .detail =
        \\Reads a password (typed twice without echo, or one line from a pipe) and stores only a hash of it. Use
        \\it to sign in to the administration pages in a browser; the buttons for starting
        \\and cancelling imports (if enabled) need this sign-in. Running it again changes
        \\the password and signs out existing sessions.
        \\See `dksearch help admin` for the whole setup.
        \\
        ,
    },
    .{
        .name = "init",
        .synopsis = "init [FILE]",
        .summary = "Write a starter configuration file (default: dksearch.toml)",
        .detail =
        \\Writes a commented starter configuration to FILE (default dksearch.toml in the
        \\current directory). It never overwrites an existing file. The file has the
        \\search settings and, commented out with the exact steps to turn it on, the
        \\administration interface ([admin]), plus an example source. Edit it, check it
        \\with `dksearch check-config FILE`, then import and serve.
        \\
        ,
    },
    .{
        .name = "check-config",
        .synopsis = "check-config FILE",
        .summary = "Validate a configuration file without starting anything",
        .detail =
        \\Reads FILE, checks every setting and every source's options (unknown keys, wrong
        \\types and out-of-range values are errors that name the key) and prints `ok` or the
        \\first problem. Nothing is opened or created.
        \\
        ,
    },
    .{
        .name = "eval",
        .synopsis = "eval [--config FILE] [-k N] [--json] JUDGMENTS",
        .summary = "Measure how well the ranking finds the documents you judged relevant",
        .detail =
        \\JUDGMENTS is a text file with one JSON object per line, naming a query and the
        \\documents (by URL or id) that are relevant to it:
        \\    {"query": "lighthouse keeper", "relevant": ["https://example.org/keeper"]}
        \\    {"query": "tides", "relevant": {"https://example.org/tides": 3, "https://example.org/moon": 1}}
        \\A list means all are equally relevant; an object gives grades (1 and up).
        \\
        \\Runs each query against the index and prints precision and recall at N (default
        \\10, at most 100), the reciprocal rank of the first relevant hit, nDCG, and where
        \\each judged document ranked. --json prints the same as one JSON object.
        \\
        ,
    },
};

pub fn find(name: []const u8) ?*const Command {
    for (&commands) |*c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

pub const admin_topic =
    \\Setting up the administration interface
    \\
    \\The administration interface is separate from the public search: its own address
    \\and port, off unless you set it up, and it only starts if a credential exists.
    \\
    \\1. Add an [admin] table to your configuration file (dksearch.toml). The file
    \\   written by `dksearch init` already has it, commented out: just remove the '#'.
    \\
    \\       [admin]
    \\       address = "127.0.0.1"    # keep it on this machine; see the manual for remote use
    \\       port = 8081
    \\       # actions = true         # also allow starting/cancelling imports from the pages
    \\
    \\2. Create a credential (as the user that runs dksearch, so the file gets the
    \\   right owner). You can create either or both:
    \\
    \\       dksearch admin-token    --config dksearch.toml   # prints a token ONCE
    \\       dksearch admin-password --config dksearch.toml   # for signing in with a browser
    \\
    \\   Only hashes are stored, in data_dir/admin-secrets.toml (or the file named by
    \\   `secrets_file` in [admin]). A lost token cannot be recovered; make a new one.
    \\
    \\3. Start the server (or restart it, settings are read once at start):
    \\
    \\       dksearch serve --config dksearch.toml
    \\
    \\   It prints the admin address. With no credential the admin interface stays off
    \\   and `serve` says so.
    \\
    \\4. Use it:
    \\   - Browser: open http://127.0.0.1:8081/ and sign in with the password.
    \\   - Command line:
    \\       curl -H "Authorization: Bearer TOKEN" http://127.0.0.1:8081/api/v1/admin/status
    \\
    \\What it shows: a dashboard with a live progress bar for a running import, your
    \\sources and their last imports, import jobs with why pages were skipped, counters,
    \\and a query-testing page that shows each result's ranking score.
    \\
    \\With `actions = true` (and the server started with --config) you can also, from
    \\the pages: start and cancel imports; add, edit, enable, disable and delete
    \\sources (it rewrites the [[source]] tables of your config file, keeping a .bak
    \\copy); and run check, backup (set `backup_dir` in [admin]) and remove-a-source.
    \\
    \\Security: never expose it over plain HTTP beyond this machine (the token and
    \\password would cross the network in clear text). For remote use, put it behind an
    \\SSH tunnel (ssh -L 8081:127.0.0.1:8081 server) or an HTTPS reverse proxy, and then
    \\set `cookie_secure = true`. More: `man dksearch`, SECURITY CONSIDERATIONS, and
    \\docs/deploy/README.md.
    \\
;

pub const config_topic =
    \\The configuration file (TOML)
    \\
    \\Every command that takes --config reads this file. Everything is optional;
    \\without --config built-in defaults are used. Check a file with
    \\`dksearch check-config FILE`. Settings are read once at start (restart to apply).
    \\
    \\    [storage]
    \\    data_dir = "data"              # where the databases live (default: ./data)
    \\
    \\    [server]                       # the public search website and API
    \\    address = "127.0.0.1"
    \\    port = 8080
    \\    # access_log = "/var/log/dksearch/access.log"   # one line per request, no queries
    \\
    \\    # [admin]                      # the administration interface: OFF until you remove the
    \\    # address = "127.0.0.1"        # leading '#' here AND create a credential with
    \\    # port = 8081                  # `dksearch admin-password`; see `dksearch help admin`
    \\
    \\    [index]
    \\    tokenizer = "unicode61"        # or "porter" for English stemming (then run rebuild)
    \\
    \\    [search]
    \\    fuzzy = "auto"                 # typo tolerance (default): "auto", "always" or "off"
    \\    regex = true                   # the regex filter on the search page and API (default on)
    \\    # regex_max_candidates = 200   # limits keep expensive patterns cheap; see the manual
    \\
    \\    [[source]]                     # zero or more: what to import
    \\    name = "my-notes"
    \\    kind = "files"                 # files, gutenberg, wikipedia, feeds, crawl, archive
    \\    path = "/home/me/notes"
    \\
    \\Each kind has its own keys: see `man dksearch` (CONFIGURATION) and
    \\docs/deploy/dksearch.toml.example for an annotated example of every kind.
    \\
;

pub const start_topic =
    \\Getting started
    \\
    \\1. Write a starter configuration file:   dksearch init
    \\   then edit dksearch.toml to name what to index (`dksearch help config`), e.g.
    \\
    \\       [[source]]
    \\       name = "my-notes"
    \\       kind = "files"
    \\       path = "/home/me/notes"
    \\
    \\2. Import it:            dksearch import --config dksearch.toml my-notes
    \\3. Run the search:       dksearch serve  --config dksearch.toml
    \\4. Open it:              http://127.0.0.1:8080/
    \\
    \\Next: set up the administration interface (`dksearch help admin`), back up
    \\(`dksearch help backup`), and look at the other kinds of source (`man dksearch`).
    \\
;

/// The overview shown by `dksearch --help` and `dksearch help`.
pub fn writeOverview(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("dksearch - a self-hosted search engine\n\n");
    try w.writeAll("usage: dksearch COMMAND [options]       (dksearch help COMMAND for details)\n\n");
    try w.writeAll("Commands:\n");
    for (&commands) |c| try w.print("  {s:<15} {s}\n", .{ c.name, c.summary });
    try w.writeAll("  help [TOPIC]    Show help for a command or a topic\n\n");
    try w.writeAll("Topics:   start    a first run in four steps\n");
    try w.writeAll("          config   what goes in the configuration file\n");
    try w.writeAll("          admin    how to set up the administration interface\n\n");
    try w.writeAll("Options:  -h, --help    this text (also after a command: dksearch serve --help)\n");
    try w.writeAll("          -V, --version print the version\n\n");
    try w.writeAll("New here? `dksearch help start`. Setting up the admin interface? `dksearch help admin`.\n");
    try w.writeAll("The full reference is the manual: man dksearch (docs/manpages/dksearch.1.md).\n");
}

/// `dksearch help TOPIC`; false if there is no such command or topic.
pub fn writeTopic(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!bool {
    if (std.mem.eql(u8, name, "admin")) {
        try w.writeAll(admin_topic);
    } else if (std.mem.eql(u8, name, "config")) {
        try w.writeAll(config_topic);
    } else if (std.mem.eql(u8, name, "start")) {
        try w.writeAll(start_topic);
    } else if (find(name)) |c| {
        try w.print("usage: dksearch {s}\n\n{s}\n\n", .{ c.synopsis, c.summary });
        try w.writeAll(c.detail);
    } else return false;
    return true;
}

const testing = std.testing;

test "every command has complete help and appears in the overview" {
    var buf: [16 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeOverview(&w);
    const overview = w.buffered();
    for (&commands) |c| {
        try testing.expect(c.summary.len > 10 and c.detail.len > 40);
        try testing.expect(std.mem.startsWith(u8, c.synopsis, c.name));
        try testing.expect(std.mem.indexOf(u8, overview, c.name) != null);
        var b2: [4096]u8 = undefined;
        var w2: std.Io.Writer = .fixed(&b2);
        try testing.expect(try writeTopic(&w2, c.name));
        try testing.expect(std.mem.indexOf(u8, w2.buffered(), c.synopsis) != null);
    }
    // The overview points at the admin setup; the admin and token help say how.
    try testing.expect(std.mem.indexOf(u8, overview, "dksearch help admin") != null);
    try testing.expect(std.mem.indexOf(u8, admin_topic, "[admin]") != null);
    try testing.expect(std.mem.indexOf(u8, admin_topic, "admin-token") != null);
    try testing.expect(std.mem.indexOf(u8, admin_topic, "admin-password") != null);
    try testing.expect(std.mem.indexOf(u8, admin_topic, "Authorization: Bearer") != null);
    var b3: [64]u8 = undefined;
    var w3: std.Io.Writer = .fixed(&b3);
    try testing.expect(!(try writeTopic(&w3, "no-such-thing")));
}
