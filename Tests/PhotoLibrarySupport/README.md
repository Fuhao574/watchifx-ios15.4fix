# Photo Library Support host checks

From the repository root on macOS:

```sh
python3 -B Tests/PhotoLibrarySupport/test_response_context.py
python3 -B Tests/PhotoLibrarySupport/test_snapshot_reply.py
python3 -B Tests/PhotoLibrarySupport/test_asset_request.py
python3 -B Tests/PhotoLibrarySupport/test_export_callback.py
```

Compiles the production response-context helper with Foundation-only mocks.
The protobuf mock deliberately lacks `outgoingResponseIdentifier`, matching the
retained iOS 15.4 contract. Exercises callback precedence, embedded context,
nil/unsupported objects and both production call sites without changing message IDs.

No device connection, Photos access, real IDS message or resource transfer occurs.
Passing tests do not establish Watch receipt, import or visible photos.

The snapshot test extracts the production reply branch unchanged, compiles it
with local request/writer/transport mocks and exercises 20 repeated requests.
Snapshot replies must not send a fresh sync signal and create a handshake loop.
Both serial-queue and no-queue branches are covered; no Photos or IDS code is run.

`WATCHFIX_PHOTO_DIAGNOSTICS=1` is an explicit test build option. Default builds
do not create private event logs. Device context1 reached snapshot acceptance
but no visible photos; context2 device validation was interrupted by service
backoff and the original phone component was restored. Neither is a complete fix.
Diagnostic and default builds use separate object directories, preventing an
incremental build from accidentally carrying test logging into a default package.

The asset request test compiles the production structural parser. Field wire
types are checked before reads; wrong lengths, duplicate UUID fields, reader
errors and over-budget requests are refused. It uses synthetic bytes only.

The export-completion test extracts the actual production callback. Native
iOS 15.4 provides temporaryFile, metadata and error separately; its URL-only
temporary-file mock intentionally has no metadata method. The test suspends
the queue to verify lifetime and metadata capture, then checks one resource
send with transport mocks. Device context3 created albums but not visible
photos and restarted after export. Context4 fixes this completion contract.

Device follow-up on iOS 15.4 / watchOS 11.5: context4 naturally launched after
system scheduling delay; the retained bounded log records 15 successful exports
and 15 locally accepted resource sends. The user confirmed actual photos inside
the album, not only album names. That is device evidence separate from host tests;
it does not establish complete album convergence or long-term stability. No photo
content, identifiers or private diagnostic receipts are included in the repository.
