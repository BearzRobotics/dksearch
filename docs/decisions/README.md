# Decision records

Each record states the context, the options considered, the decision and who made it. SPEC section 16 lists the open decisions; this table shows where each stands.

| SPEC 16 item | Status | Record |
|---|---|---|
| 1. Index backend | decided: SQLite FTS5 (vendored) | 0003 |
| 2. Metadata/operational database | decided: SQLite files | 0006 |
| 3. Content storage and retention | decided: compressed text in SQLite, retention per source | 0006, 0008 |
| 4. Frontend and assets | decided: server-rendered HTML, embedded stylesheet | 0004 |
| 5. API protocol, versioning, authentication | decided: versioned JSON; admin token and password | 0004, 0012 |
| 6. Languages and tokenization | English first; `unicode61` default, optional `porter`; CJK deferred | 0007, 0013 |
| 7. Installation targets and service integration | decided minimally: Linux and systemd from source | 0015 |
| 8. Connector packaging and plugin boundary | built-in connectors behind one interface, chosen at compile time (`-Dwikipedia`, `-Dfeeds`); no runtime plugins | 0002, 0007, 0011, 0016 |
| 9. Index partitioning and multi-collection | open | |
| 10. Federation trust and synchronization | open | |

| Record | Subject |
|---|---|
| 0001 | Zig 0.17.1 and the vendored TOML parser |
| 0002 | Core module layout |
| 0003 | Search index backend |
| 0004 | HTTP server, API format, public frontend |
| 0005 | License (GPL-2.0-only) |
| 0006 | Persistent storage |
| 0007 | First dataset connectors and format dependencies |
| 0008 | Import runner, sources, batched writes |
| 0009 | Integrity check and backup |
| 0010 | Removing documents |
| 0011 | Wikipedia connector |
| 0012 | Admin interface, authentication, logging |
| 0013 | Optional English stemming |
| 0014 | Admin actions |
| 0015 | Installation targets |
| 0016 | Feeds connector and the XML build split |
| 0017 | Crawler direction, feed fetching, Windows, rights override |
| 0018 | Web crawler connector |
| 0019 | Internet Archive metadata connector |
| 0020 | Regular-expression search |
| 0021 | A time limit for searches |
| 0022 | Administration interface: look, live progress, maintenance, source editing |
| 0024 | Query language and typo tolerance |
| 0025 | ZIM (Kiwix) connector |
| 0026 | Our own XML library (xml-zig), vendored |
| 0027 | Showing documents: md-zig and an allow-list sanitizer |
| 0028 | Downloading ZIM files from the Kiwix library |
| 0029 | Ranking controls, stop words and synonyms, schedules, skip examples |
| 0030 | Retrieval API for RAG |
| 0031 | Typo tolerance from the index's vocabulary (edit distance 2) |
| 0032 | Crawler concurrency and breadth-first order |
| 0033 | Collections and API keys |
| 0034 | Peers and federated search |
| 0035 | Opening office files in a document server |
| 0036 | Conditional requests when crawling again |
| 0037 | One connector for archives and dumps |
| 0038 | Semantic search, opt-in |
| 0039 | Replicating a peer's documents |
| 0040 | Signed node identity |
| 0041 | Fallback to other search engines |
| 0042 | Ollama, models and written answers |
| 0043 | A vector index over every document |
| 0044 | Crawling Tor and I2P sites |
| 0045 | More than one excerpt per result |
| 0046 | Similar documents |
| 0047 | Cursor paging |
| 0048 | Domain lists and safe search |
| 0049 | Safe search that adults can turn off |
| 0050 | Regular expressions over characters |
| 0051 | Adaptive recrawl of pages |
