# YaCy

Status: source read; two-node private experiment partly done (peers paired, crawl and local search work, remote search result unresolved). Research order: 2 of 10.

- Focus: peer-to-peer indexing, discovery and distributed queries.
- Source: <https://github.com/yacy/yacy_search_server>, shallow clone at `/mnt/scratch/research/yacy_search_server`, commit `eba3f94b4376` (2026-11-03). Experiments use the release `yacy_v1.942_202608150808_f9c4b9700` (downloaded from download.yacy.net, sha256 `2cb3200c951a93db8aa0ece0ea72aaeebce62385b75bff4e690793ec2c32f99f`), unpacked twice under `/mnt/scratch/research/yacy-run`.
- Claims marked (read) were checked in the files named; (observed) come from the experiment; (known) are from prior knowledge and not yet checked.

## Architecture as read from the source

All paths under `source/net/yacy/`.

**Peers and identity (read).** A peer is a `Seed` (`peers/Seed.java`): a map of properties (hash, name, IPs, port, version, peer type, counts of links and words, last-seen time) serialised as a short string (`z|` prefix = gzip + base64). The peer hash is 12 base-64 characters and is *chosen*, not derived from a key: `Seed.genLocalSeed` picks a random one and `bestGap` / `hashGaps` pick a position in the largest gap between known peers on the hash ring, so peers spread evenly. There is no cryptographic identity: nothing signs a seed (so a peer can claim any hash).

**Peer types (read).** `virgin` (never reached anyone), `junior` (cannot be reached from outside), `mentee`/`mentor` (a junior using a senior as its server), `senior` (reachable), `principal` (a senior that also uploads the seed list to a web host). Only `senior` and `principal` seeds are accepted by `PeerActions.connectPeer`; a `virgin` or `junior` seed is rejected ("NOT QUALIFIED"). A peer becomes `senior` when another peer confirms it can reach it, or, with no peers found, when it has a proper IP (`Network.java`, "to start bootstrapping, we need to be recognised as senior"). The seed also records the peer's own seed-list URL.

**Discovery and bootstrap (read).** `network.unit.bootstrap.seedlist0..N` in the network definition name seed-list URLs (the public network lists three community servers). `Switchboard.loadSeedLists` downloads each (`SeedDB.loadSeedListConcurrently`: a HEAD for age, then a GET of lines of seeds; entries newer than four hours, or the first ten, are connected). Peers then exchange seeds in the `hello` and `seedlist` servlets (`htroot/yacy/`); a peer that publishes itself pings seniors every 30 seconds (`Network.java`, `PeerPing`).

**Network definitions (read).** A network is a unit file (`defaults/yacy.network.*.unit`): name, `domain` (global or local), whether DHT is on, DHT redundancy for juniors and seniors (3 for seniors on the public network), the vertical partition exponent (4 on the public network, so 16 partitions), remote-search time and count limits (3000 ms, 10), seed-list URLs, an access whitelist and blacklist, and whether remote search results are verified. Peers of different networks refuse each other. `freeworld` is the public network; `intranet` is local, with DHT off; others (`allip`, `webportal`) are variants.

**Word hashes and the reverse word index (read).** A word is lowercased and hashed with MD5, encoded to 12 characters in YaCy's base-64 order (`kelondro/data/word/Word.word2hash`). The index ("RWI", reverse word index) maps a word hash to a container of references; one reference (`WordReferenceRow`) is a fixed row of about 19 small columns: the URL hash (12 characters), last-modified day, words in title, words in text, phrases, doctype, language, local and outside link counts, URL length and components, type of word, flags, hit count, position in text, position in phrase, phrase position, word distance. Containers are held in memory (`ReferenceContainerCache`) and flushed to sorted files (`ReferenceContainerArray`, `IndexCell`, `IODispatcher`); this is the Kelondro storage layer. The documents themselves (title, text, URL metadata) are in an embedded Solr/Lucene index (`search/index/Fulltext.java` imports `org.apache.solr`).

**DHT (read).** `cora/federate/yacy/Distribution.java`: a word's DHT position is the 63-bit number of its hash in base-64 order; distance wraps around a closed ring (`horizontalDHTDistance`). With partition exponent *n* there are 2^n *vertical* partitions: the hash space of each word is split so that a word's references are spread over 2^n peers (by URL hash), and each partition is held by `redundancy` peers (`peers/DHTSelection.java`: `selectDHTDistributionTargets`, `selectDHTSearchTargets`, `collectHorizontalDHTPositions`). A peer sends the references of words it holds to the peers whose hash is closest to each word's position (`peers/Dispatcher`, `Transmission`), at `transferRWI`, then `transferURL` for the metadata of URLs the receiver does not know.

**Receiving index (read).** `htroot/yacy/transferRWI.java`: receiving is switched by `allowReceiveIndex` (and refused in "robinson" mode, when the receiver is too busy, when the sender is unknown, or for blacklisted URLs); the reply is `ok`, `not_granted`, `busy`, or a list of unknown URL hashes to ask for. There is no check of what the sender claims beyond that.

**Remote search (read).** `peers/RemoteSearch.java` and `peers/Protocol.java`: a search hashes the query words, selects peers from the DHT for those hashes (plus a few random ones, "robinson" peers, for extra coverage; the share depends on partitions and redundancy), asks them in parallel with a time limit (`remotesearch.maxtime` 3000 ms) and count limit, and merges the answers (references plus URL metadata and snippets) with the local result, ranked together. A reference carries enough to rank without fetching the document. With `inspection.searchverify` the receiver can check results against the real page.

**Crawling (read, partly).** Crawl profiles, per-host delay, robots.txt, a `NoticedURL` queue with stacks per kind (local, global, remote, no-load), and *remote crawl*: a peer offers URLs from its stack for others to fetch (`network.unit.remotecrawl.speed`), with a `crawlReceipt` servlet to report results.

## Observations from the source about trust and abuse

- No signatures: seed contents and references are claimed, not proven. `transferRWI` accepts references for URLs it can later check (`transferURL`), and `searchverify` is the defence for search results. Reputation, in the sense of scoring peers by past behaviour, was not found in the code read (a search for such a mechanism in `peers/` found only blacklists, the fraud check "double hashes on same port" in `connectPeer`, and per-peer counters).
- Anyone who can pick a hash position can place themselves next to a popular word's position and answer for it (index poisoning and censorship are possible); partition redundancy and random extra peers are the mitigation.
- The word hash is 12 characters of an MD5 digest: no collision handling beyond a re-hash of rare cases (`word2hash`).

## Experiments

Environment: two YaCy 1.942 nodes on this machine (`labA` on port 8091, `labB` on 8092), a private network unit `dksearchlab` (copy of `intranet` with DHT on, partition exponent 0, redundancy 1, access whitelist limited to this host), no contact with the public network (no public seed list is configured; the nodes are given only each other's address). A tiny local site (11 pages with invented words) is served on 127.0.0.1:9100 for node A to crawl.

Results (the experiment is incomplete; what follows is what was observed, and the one result that was wanted, a search on one node finding a document only the other node holds, was **not** obtained):

- (observed) The start script reads `key=value` without spaces around `=`; with spaces the port and memory settings are silently ignored. The node name and `staticIP` settings did not take effect as hoped (the seed showed an empty IP and a random name until edited).
- (observed) **Cold start of a private two-node network is hard.** A new node is `virgin`. `PeerActions.connectPeer` accepts only `senior` or `principal` seeds, and a node becomes `senior` only when another peer confirms it can reach it (or by the junior path in `Network.java`, which a `virgin` node does not take). With an empty seed list nobody can be the first senior. What worked: node B asked node A directly through the admin page's "add peer" form (`/Network.html?page=4&addPeer=1&peerHash=..&peerIP=..&peerPort=..`), which sends a `hello`; A called B back, found it reachable, told it `yourtype = senior`, and registered it. The reverse direction does not work: A stays `virgin` in B's eyes, so only A knew B. Restarting a node resets its type to `virgin`, so the handshake has to be repeated after every restart.
- (observed) The crawl works as documented: a node crawled a local site (11 pages, depth 2) and found its pages in a local search; a second node that crawled the same site found the same.
- (observed) A new peer is not asked for remote searches until it is old enough: seeds younger than `minage` (3 days in `RemoteSearch`) are penalised in selection, so a lab node needed its birth date edited in `DATA/INDEX/<network>/NETWORK/mySeed.txt` before node A chose it ("dhtPeers=1" appeared in the log only then).
- (observed) With that done, A's global search asked B, and B answered ("remote search: peer labB sent 1 topics ... 0/0 references") but returned no references for a word only B had indexed, although B finds the page in its own local search. The cause was not found in the time spent (candidates: the word-index part of the answer being empty because of how this version splits work between its Solr index and the word index; a request-rate or load check in `htroot/yacy/search.java`; the peers' state after the restarts). It is recorded as unresolved rather than guessed.
- (read) Membership of a network can be controlled by a shared secret: `network.unit.protocol.control` is `uncontrolled` (anyone speaking the protocol), or a method such as `salted-magic-sim` in which a request proves knowledge of a network-wide secret (`Protocol.authentifyRequest`). Peers also refuse requests carrying a different network name. A private network is therefore a unit file, a name and, optionally, a shared secret.

What this says for dksearch, from the cold-start difficulty alone: the YaCy bootstrap assumes a populated public network; a private two-node network needs an explicit pairing step. A dksearch design should make pairing explicit and persistent (an operator adds a peer by address and a shared key; nothing depends on discovering seniors), and should not lose pairings on restart.

Time used: about three hours, mostly on bootstrap. The nodes are stopped; their directories are kept at `/mnt/scratch/research/yacy-run` (176 MB each) so the experiment can be continued (sites in `site` and `site2`, served on 127.0.0.1:9100 and :9101).

## Useful patterns

- A network unit file: one small declarative file defines what a network is (DHT or not, redundancy, limits, bootstrap lists, access rules). dksearch's "private/local-only operation always possible" maps onto it directly.
- Fixed-width reference rows with the ranking features inside, so a remote peer can rank without the document.
- Querying a few peers with a hard time limit and merging partial results.
- Choosing a hash position in the largest gap, to balance load.

## Limitations and trade-offs

- Java, Solr, a large code base; the storage layer (Kelondro) is its own format. Not something to adopt, only to learn from.
- Public-network behaviour (spam, poisoned references, abandoned peers) is a known problem for this design; the private-network unit avoids most of it.
- The index shared is the word-to-document reference, not the text: a remote peer needs the original page (or its own cache) to show a snippet.

## Potential dksearch applications

(To be filled in after the experiments. Candidates: remote query execution between trusted nodes before any index exchange; a network-unit-style config; word-hash partitioning only if index exchange is ever wanted; signed peer identity, which YaCy lacks.)

## Questions for dksearch

- Remote queries or index exchange? YaCy does both; for dksearch's private networks remote queries alone avoid the poisoning problem entirely and keep each node's data its own. Experiment: does the two-node case behave that way?
- Document identity across nodes: YaCy uses a hash of the URL (so two peers agree on a document); dksearch derives ids from source name and source id, which two nodes would not share.
