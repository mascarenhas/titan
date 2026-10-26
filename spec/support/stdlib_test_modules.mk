# Audit expectation for compiler-discovered native test owners on every platform.
# This is runtime scheduling/reporting data, not a compiler input or module DAG.
# Runtime filters select cases only after the complete graph is compiled.
# Keep the first owner explicit to preserve the aggregate's provider identity.
TITAN_STDLIB_TEST_PROGRAM_ROOT := test.tests
TITAN_STDLIB_TEST_PROGRAM_OUTPUT := test/tests
TITAN_STDLIB_TEST_ROOTS := $(TITAN_STDLIB_TEST_PROGRAM_ROOT) \
	coroutine.tests iteration.tests gc.tests lua.tests math.tests peg.tests \
	string.core_test string.format_pack_test string.regex_test async.tests \
	uv.task_tests uv.public_tests io.tests fs.tests timer.tests net.tests ssl.tests http.tests websocket.tests \
	url.tests path.tests os.tests os.process_tests uv.runtime_tests reflect.tests sqlite3.tests json.tests protobuf.tests thread.tests

# Per-owner measured validation durations (seconds) and timing-sensitive guards.
# Guarded owners contain short TLS/HTTP/WebSocket/timer/TCP deadlines or host
# wall-clock assertions and run alone in one serial pass after the ordinary
# worker pool drains, with no concurrent Busted workers or native build.
# uv.runtime_tests's 60s shutdown ticker is closed synchronously by uv_walk and
# its 15s deadline oracle is an explicit filtered CI step, while its remaining
# 58.8s is fresh-process fixture compilation, so it stays in the ordinary pool.
# Unlisted roots fall back to 1.0s and ordinary scheduling.
TITAN_STDLIB_TEST_SECONDS_test.tests := 0.9
TITAN_STDLIB_TEST_SECONDS_coroutine.tests := 0.9
TITAN_STDLIB_TEST_SECONDS_iteration.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_gc.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_lua.tests := 7.6
TITAN_STDLIB_TEST_SECONDS_math.tests := 0.2
TITAN_STDLIB_TEST_SECONDS_peg.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_string.core_test := 0.1
TITAN_STDLIB_TEST_SECONDS_string.format_pack_test := 0.1
TITAN_STDLIB_TEST_SECONDS_string.regex_test := 0.1
TITAN_STDLIB_TEST_SECONDS_async.tests := 18.9
TITAN_STDLIB_TEST_SECONDS_uv.task_tests := 0.1
TITAN_STDLIB_TEST_SECONDS_uv.public_tests := 18.1
TITAN_STDLIB_TEST_SECONDS_io.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_fs.tests := 4.0
TITAN_STDLIB_TEST_SECONDS_timer.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_net.tests := 0.2
TITAN_STDLIB_TEST_SECONDS_ssl.tests := 8.1
TITAN_STDLIB_TEST_SECONDS_http.tests := 6.6
TITAN_STDLIB_TEST_SECONDS_websocket.tests := 42.5
TITAN_STDLIB_TEST_SECONDS_url.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_path.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_os.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_os.process_tests := 45.8
TITAN_STDLIB_TEST_SECONDS_uv.runtime_tests := 58.8
TITAN_STDLIB_TEST_SECONDS_reflect.tests := 0.1
TITAN_STDLIB_TEST_SECONDS_sqlite3.tests := 5.3
TITAN_STDLIB_TEST_SECONDS_json.tests := 0.6
TITAN_STDLIB_TEST_SECONDS_protobuf.tests := 0.4
TITAN_STDLIB_TEST_SECONDS_thread.tests := 39.0

TITAN_STDLIB_TEST_GUARD_timer.tests := 1
TITAN_STDLIB_TEST_GUARD_net.tests := 1
TITAN_STDLIB_TEST_GUARD_ssl.tests := 1
TITAN_STDLIB_TEST_GUARD_http.tests := 1
TITAN_STDLIB_TEST_GUARD_websocket.tests := 1
TITAN_STDLIB_TEST_GUARD_os.tests := 1

.PHONY: print-stdlib-test-roots print-stdlib-test-owner-schedule
print-stdlib-test-roots:
	@printf '%s\n' $(TITAN_STDLIB_TEST_ROOTS)

print-stdlib-test-owner-schedule:
	@printf '%s\n' $(foreach root,$(TITAN_STDLIB_TEST_ROOTS),$(root):$(or $(TITAN_STDLIB_TEST_SECONDS_$(root)),1.0):$(if $(filter 1,$(TITAN_STDLIB_TEST_GUARD_$(root))),guarded,ordinary))
