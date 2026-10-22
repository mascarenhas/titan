# All platforms compile this complete native test inventory. Runtime filters
# select cases only after compilation; platform differences belong in named
# cases and classified skips, never in a second root or case allowlist.
# --test gives its first root ownership of the aggregate executable path.
TITAN_STDLIB_TEST_PROGRAM_ROOT := test.tests
TITAN_STDLIB_TEST_PROGRAM_OUTPUT := test/tests
TITAN_STDLIB_TEST_ROOTS := $(TITAN_STDLIB_TEST_PROGRAM_ROOT) \
	coroutine.tests iteration.tests gc.tests lua.tests math.tests peg.tests \
	string.core_test string.format_pack_test string.regex_test async.tests \
	uv.task_tests uv.public_tests io.tests fs.tests timer.tests net.tests ssl.tests http.tests websocket.tests \
	url.tests path.tests os.tests os.process_tests uv.runtime_tests reflect.tests sqlite3.tests json.tests protobuf.tests thread.tests

.PHONY: print-stdlib-test-roots
print-stdlib-test-roots:
	@printf '%s\n' $(TITAN_STDLIB_TEST_ROOTS)

# Reviewed native-test compilation units and direct source imports.
# Update when adding/removing a contributor or changing a source import.
TITAN_TEST_MODULES := async.test_support \
	async.tests \
	coroutine.test_support \
	coroutine.tests \
	fs.test_support \
	fs.tests \
	gc.tests \
	http.test_support \
	http.tests \
	io.test_support \
	io.tests \
	iteration.tests \
	json.tests \
	lua.handle_transfer_fixture \
	lua.preload_fixture \
	lua.receiver_fixture \
	lua.test_support \
	lua.transfer_fixture \
	lua.tests \
	math.tests \
	net.test_support \
	net.tests \
	os.process_test_support \
	os.process_tests \
	os.test_support \
	os.tests \
	path.tests \
	peg.test_support \
	peg.tests \
	protobuf.tests \
	reflect.tests \
	sqlite3.tests \
	ssl.backpressure_support \
	ssl.test_support \
	ssl.tests \
	string.core_test \
	string.format_pack_test \
	string.regex_test \
	string.test_support \
	support.async \
	support.command \
	support.common \
	support.runtime \
	test.tests \
	thread.tests \
	timer.tests \
	url.tests \
	uv.public_tests \
	uv.runtime_tests \
	uv.task_test_support \
	uv.task_tests \
	websocket.tests

TITAN_TEST_SOURCES_async.test_support := spec/stdlib/titan/async/test_support.titan
TITAN_TEST_IMPORTS_async.test_support :=

TITAN_TEST_SOURCES_async.tests := spec/stdlib/titan/async/tests/tests.titan \
	spec/stdlib/titan/async/tests/all_join_test.titan \
	spec/stdlib/titan/async/tests/any_race_test.titan \
	spec/stdlib/titan/async/tests/await_test.titan \
	spec/stdlib/titan/async/tests/channel_test.titan \
	spec/stdlib/titan/async/tests/coalescing_receiver_test.titan \
	spec/stdlib/titan/async/tests/completion_test.titan \
	spec/stdlib/titan/async/tests/external_wait_test.titan \
	spec/stdlib/titan/async/tests/fatal_test.titan \
	spec/stdlib/titan/async/tests/foreign_work_test.titan \
	spec/stdlib/titan/async/tests/receiver_test.titan \
	spec/stdlib/titan/async/tests/runtime_close_test.titan \
	spec/stdlib/titan/async/tests/subscription_test.titan \
	spec/stdlib/titan/async/tests/task_test.titan \
	spec/stdlib/titan/async/tests/transfer_payload_test.titan \
	spec/stdlib/titan/async/tests/transfer_scalar_envelope_test.titan \
	spec/stdlib/titan/async/tests/transfer_scope_reuse_test.titan \
	spec/stdlib/titan/async/tests/coverage_combinator_matrix_test.titan \
	spec/stdlib/titan/async/tests/coverage_recovery_test.titan
TITAN_TEST_IMPORTS_async.tests := async.test_support support.async support.command support.common support.runtime
TITAN_TEST_FOREIGN_async.tests := 1

TITAN_TEST_SOURCES_coroutine.test_support := spec/stdlib/titan/coroutine/test_support.titan
TITAN_TEST_IMPORTS_coroutine.test_support :=

TITAN_TEST_SOURCES_coroutine.tests := spec/stdlib/titan/coroutine/tests/tests.titan \
	spec/stdlib/titan/coroutine/tests/basic_test.titan \
	spec/stdlib/titan/coroutine/tests/gc_test.titan \
	spec/stdlib/titan/coroutine/tests/lifecycle_test.titan \
	spec/stdlib/titan/coroutine/tests/lua_boundary_test.titan \
	spec/stdlib/titan/coroutine/tests/nested_test.titan \
	spec/stdlib/titan/coroutine/tests/running_test.titan
TITAN_TEST_IMPORTS_coroutine.tests := coroutine.test_support support.command support.common

TITAN_TEST_SOURCES_fs.test_support := spec/stdlib/titan/fs/test_support.titan
TITAN_TEST_IMPORTS_fs.test_support := support.common

TITAN_TEST_SOURCES_fs.tests := spec/stdlib/titan/fs/tests.titan
TITAN_TEST_IMPORTS_fs.tests := fs.test_support support.async support.common support.runtime

TITAN_TEST_SOURCES_gc.tests := spec/stdlib/titan/gc/tests.titan
TITAN_TEST_IMPORTS_gc.tests := support.common

TITAN_TEST_SOURCES_http.test_support := spec/stdlib/titan/http/test_support.titan
TITAN_TEST_IMPORTS_http.test_support := support.runtime

TITAN_TEST_SOURCES_http.tests := spec/stdlib/titan/http/tests/tests.titan \
	spec/stdlib/titan/http/tests/client_behavior.titan \
	spec/stdlib/titan/http/tests/client_reuse_test.titan \
	spec/stdlib/titan/http/tests/eof_behavior.titan \
	spec/stdlib/titan/http/tests/parent_cancel_test.titan \
	spec/stdlib/titan/http/tests/reuse_port_test.titan \
	spec/stdlib/titan/http/tests/sanitizer_process_test.titan \
	spec/stdlib/titan/http/tests/server_behavior.titan \
	spec/stdlib/titan/http/tests/test_cases.titan \
	spec/stdlib/titan/http/tests/timeout_tls_behavior.titan \
	spec/stdlib/titan/http/tests/upgrade_behavior.titan \
	spec/stdlib/titan/http/tests/transfer_test.titan \
	spec/stdlib/titan/http/tests/transfer_timeout_test.titan \
	spec/stdlib/titan/http/tests/discard_transfer_test.titan
TITAN_TEST_IMPORTS_http.tests := http.test_support support.async support.command support.common support.runtime

TITAN_TEST_SOURCES_io.test_support := spec/stdlib/titan/io/test_support.titan
TITAN_TEST_IMPORTS_io.test_support :=

TITAN_TEST_SOURCES_io.tests := spec/stdlib/titan/io/tests/tests.titan \
	spec/stdlib/titan/io/tests/core_test.titan \
	spec/stdlib/titan/io/tests/process_test.titan
TITAN_TEST_IMPORTS_io.tests := io.test_support os.process_test_support support.async support.command support.common support.runtime

TITAN_TEST_SOURCES_iteration.tests := spec/stdlib/titan/iteration/tests.titan
TITAN_TEST_IMPORTS_iteration.tests := support.common

TITAN_TEST_SOURCES_json.tests := spec/stdlib/titan/json/tests/tests.titan \
	spec/stdlib/titan/json/tests/core_test.titan \
	spec/stdlib/titan/json/tests/mapping_test.titan \
	spec/stdlib/titan/json/tests/native_storage_test.titan \
	spec/stdlib/titan/json/tests/parser_test.titan
TITAN_TEST_IMPORTS_json.tests :=

TITAN_TEST_SOURCES_protobuf.tests := spec/stdlib/titan/protobuf/tests.titan
TITAN_TEST_IMPORTS_protobuf.tests :=
TITAN_TEST_FOREIGN_protobuf.tests := 1

TITAN_TEST_SOURCES_lua.preload_fixture := spec/stdlib/titan/lua/preload_fixture.titan
TITAN_TEST_IMPORTS_lua.preload_fixture :=

TITAN_TEST_SOURCES_lua.handle_transfer_fixture := spec/stdlib/titan/lua/handle_transfer_fixture.titan
TITAN_TEST_IMPORTS_lua.handle_transfer_fixture :=

TITAN_TEST_SOURCES_lua.receiver_fixture := spec/stdlib/titan/lua/receiver_fixture.titan
TITAN_TEST_IMPORTS_lua.receiver_fixture :=

TITAN_TEST_SOURCES_lua.test_support := spec/stdlib/titan/lua/test_support.titan
TITAN_TEST_IMPORTS_lua.test_support := support.runtime

TITAN_TEST_SOURCES_lua.tests := spec/stdlib/titan/lua/tests/tests.titan \
	spec/stdlib/titan/lua/tests/core_test.titan \
	spec/stdlib/titan/lua/tests/dofile_test.titan \
	spec/stdlib/titan/lua/tests/handle_transfer_test.titan \
	spec/stdlib/titan/lua/tests/independent_state_async_test.titan \
	spec/stdlib/titan/lua/tests/independent_state_preload_test.titan \
	spec/stdlib/titan/lua/tests/independent_state_reader_test.titan \
	spec/stdlib/titan/lua/tests/independent_state_receiver_test.titan \
	spec/stdlib/titan/lua/tests/independent_state_test.titan \
	spec/stdlib/titan/lua/tests/independent_state_transfer_test.titan \
	spec/stdlib/titan/lua/tests/record_payload_test.titan \
	spec/stdlib/titan/lua/tests/require_test.titan \
	spec/stdlib/titan/lua/tests/source_require_test.titan
TITAN_TEST_IMPORTS_lua.tests := lua.handle_transfer_fixture lua.preload_fixture lua.receiver_fixture lua.test_support lua.transfer_fixture support.async support.common support.runtime
TITAN_TEST_SOURCES_lua.transfer_fixture := spec/stdlib/titan/lua/transfer_fixture.titan
TITAN_TEST_IMPORTS_lua.transfer_fixture :=
TITAN_TEST_FOREIGN_lua.transfer_fixture := 1
TITAN_TEST_FOREIGN_lua.tests := 1

TITAN_TEST_SOURCES_math.tests := spec/stdlib/titan/math/tests.titan
TITAN_TEST_IMPORTS_math.tests :=

TITAN_TEST_SOURCES_net.test_support := spec/stdlib/titan/net/test_support.titan
TITAN_TEST_IMPORTS_net.test_support := support.runtime

TITAN_TEST_SOURCES_net.tests := spec/stdlib/titan/net/tests.titan
TITAN_TEST_IMPORTS_net.tests := net.test_support support.async support.common support.runtime

TITAN_TEST_SOURCES_os.process_test_support := spec/stdlib/titan/os/process_test_support.titan
TITAN_TEST_IMPORTS_os.process_test_support := support.async support.common

TITAN_TEST_SOURCES_os.process_tests := spec/stdlib/titan/os/process_tests/process_tests.titan \
	spec/stdlib/titan/os/process_tests/exit_test.titan \
	spec/stdlib/titan/os/process_tests/host_process_test.titan \
	spec/stdlib/titan/os/process_tests/parent_stdio_test.titan \
	spec/stdlib/titan/os/process_tests/signal_test.titan \
	spec/stdlib/titan/os/process_tests/stream_test.titan \
	spec/stdlib/titan/os/process_tests/coverage_stream_test.titan \
	spec/stdlib/titan/os/process_tests/coverage_tty_test.titan \
	spec/stdlib/titan/os/process_tests/coverage_read_failure_test.titan \
	spec/stdlib/titan/os/process_tests/coverage_shutdown_admission_test.titan \
	spec/stdlib/titan/os/process_tests/transfer_test.titan
TITAN_TEST_IMPORTS_os.process_tests := os.process_test_support support.async support.command support.common support.runtime

TITAN_TEST_SOURCES_os.test_support := spec/stdlib/titan/os/test_support.titan
TITAN_TEST_IMPORTS_os.test_support := support.common

TITAN_TEST_SOURCES_os.tests := spec/stdlib/titan/os/tests/tests.titan \
	spec/stdlib/titan/os/tests/helpers_test.titan \
	spec/stdlib/titan/os/tests/time_test.titan \
	spec/stdlib/titan/os/tests/coverage_calendar_test.titan
TITAN_TEST_IMPORTS_os.tests := os.test_support support.command

TITAN_TEST_SOURCES_path.tests := spec/stdlib/titan/path/tests.titan
TITAN_TEST_IMPORTS_path.tests :=

TITAN_TEST_SOURCES_peg.test_support := spec/stdlib/titan/peg/test_support.titan
TITAN_TEST_IMPORTS_peg.test_support :=

TITAN_TEST_SOURCES_peg.tests := spec/stdlib/titan/peg/tests/tests.titan \
	spec/stdlib/titan/peg/tests/core_test.titan \
	spec/stdlib/titan/peg/tests/gc_test.titan \
	spec/stdlib/titan/peg/tests/relabel_test.titan
TITAN_TEST_IMPORTS_peg.tests := peg.test_support

TITAN_TEST_SOURCES_reflect.tests := spec/stdlib/titan/reflect/tests.titan
TITAN_TEST_IMPORTS_reflect.tests :=

TITAN_TEST_SOURCES_sqlite3.tests := spec/stdlib/titan/sqlite3/tests/tests.titan \
	spec/stdlib/titan/sqlite3/tests/transfer_test.titan \
	spec/stdlib/titan/sqlite3/tests/binding_test.titan \
	spec/stdlib/titan/sqlite3/tests/cancellation_test.titan \
	spec/stdlib/titan/sqlite3/tests/connection_test.titan \
	spec/stdlib/titan/sqlite3/tests/mapping_test.titan \
	spec/stdlib/titan/sqlite3/tests/query_test.titan \
	spec/stdlib/titan/sqlite3/tests/transaction_test.titan \
	spec/stdlib/titan/sqlite3/tests/worker_test.titan
TITAN_TEST_IMPORTS_sqlite3.tests := support.async support.command support.runtime

TITAN_TEST_SOURCES_ssl.backpressure_support := spec/stdlib/titan/ssl/backpressure_support.titan
TITAN_TEST_IMPORTS_ssl.backpressure_support := support.async

TITAN_TEST_SOURCES_ssl.test_support := spec/stdlib/titan/ssl/test_support.titan
TITAN_TEST_IMPORTS_ssl.test_support := support.runtime

TITAN_TEST_SOURCES_ssl.tests := spec/stdlib/titan/ssl/tests/tests.titan \
	spec/stdlib/titan/ssl/tests/coverage.titan \
	spec/stdlib/titan/ssl/tests/allocation_test.titan \
	spec/stdlib/titan/ssl/tests/error_strings_test.titan \
	spec/stdlib/titan/ssl/tests/late_write_test.titan \
	spec/stdlib/titan/ssl/tests/drain_failure_test.titan \
	spec/stdlib/titan/ssl/tests/transfer_test.titan
TITAN_TEST_IMPORTS_ssl.tests := support.command net.test_support ssl.backpressure_support ssl.test_support support.async support.common support.runtime

TITAN_TEST_SOURCES_string.core_test := spec/stdlib/titan/string/core_test.titan
TITAN_TEST_IMPORTS_string.core_test := string.test_support

TITAN_TEST_SOURCES_string.format_pack_test := spec/stdlib/titan/string/format_pack_test.titan
TITAN_TEST_IMPORTS_string.format_pack_test := string.test_support

TITAN_TEST_SOURCES_string.regex_test := spec/stdlib/titan/string/regex_test.titan
TITAN_TEST_IMPORTS_string.regex_test := string.test_support

TITAN_TEST_SOURCES_string.test_support := spec/stdlib/titan/string/test_support.titan
TITAN_TEST_IMPORTS_string.test_support :=

TITAN_TEST_SOURCES_support.async := spec/stdlib/titan/support/async.titan
TITAN_TEST_IMPORTS_support.async := support.runtime

TITAN_TEST_SOURCES_support.command := spec/stdlib/titan/support/command.titan
TITAN_TEST_IMPORTS_support.command := support.common

TITAN_TEST_SOURCES_support.common := spec/stdlib/titan/support/common.titan
TITAN_TEST_IMPORTS_support.common :=

TITAN_TEST_SOURCES_support.runtime := spec/stdlib/titan/support/runtime.titan
TITAN_TEST_IMPORTS_support.runtime :=

TITAN_TEST_SOURCES_test.tests := spec/stdlib/titan/test/tests.titan
TITAN_TEST_IMPORTS_test.tests := support.command support.common support.runtime

TITAN_TEST_SOURCES_thread.tests := spec/stdlib/titan/thread/tests/tests.titan \
	spec/stdlib/titan/thread/tests/ownership_test.titan \
	spec/stdlib/titan/thread/tests/teardown_test.titan \
	spec/stdlib/titan/thread/tests/wake_test.titan
TITAN_TEST_IMPORTS_thread.tests := support.async support.command support.common support.runtime

TITAN_TEST_SOURCES_timer.tests := spec/stdlib/titan/timer/tests.titan
TITAN_TEST_IMPORTS_timer.tests := support.async support.runtime

TITAN_TEST_SOURCES_url.tests := spec/stdlib/titan/url/tests.titan
TITAN_TEST_IMPORTS_url.tests :=

TITAN_TEST_SOURCES_uv.public_tests := spec/stdlib/titan/uv/public_tests/public_tests.titan \
	spec/stdlib/titan/uv/public_tests/abandonment.titan \
	spec/stdlib/titan/uv/public_tests/lifecycle.titan \
	spec/stdlib/titan/uv/public_tests/requests.titan \
	spec/stdlib/titan/uv/public_tests/network.titan \
	spec/stdlib/titan/uv/public_tests/process.titan \
	spec/stdlib/titan/uv/public_tests/workers.titan \
	spec/stdlib/titan/uv/public_tests/outputs.titan \
	spec/stdlib/titan/uv/public_tests/coverage_fs_poll.titan \
	spec/stdlib/titan/uv/public_tests/coverage_sync_udp.titan \
	spec/stdlib/titan/uv/public_tests/coverage_misc_callbacks.titan \
	spec/stdlib/titan/uv/public_tests/coverage_tty.titan \
	spec/stdlib/titan/uv/public_tests/external_wake.titan \
	spec/stdlib/titan/uv/public_tests/transfer.titan
TITAN_TEST_IMPORTS_uv.public_tests := lua.receiver_fixture support.common support.command support.runtime
TITAN_TEST_FOREIGN_uv.public_tests := 1

TITAN_TEST_SOURCES_uv.runtime_tests := spec/stdlib/titan/uv/runtime_tests.titan
TITAN_TEST_IMPORTS_uv.runtime_tests := support.command support.common support.runtime

TITAN_TEST_SOURCES_uv.task_test_support := spec/stdlib/titan/uv/task_test_support.titan
TITAN_TEST_IMPORTS_uv.task_test_support := support.runtime

TITAN_TEST_SOURCES_uv.task_tests := spec/stdlib/titan/uv/task_tests/task_tests.titan \
	spec/stdlib/titan/uv/task_tests/cancellation_test.titan \
	spec/stdlib/titan/uv/task_tests/continuations_test.titan
TITAN_TEST_IMPORTS_uv.task_tests := support.async support.runtime uv.task_test_support

# Project-private C declarations and generated native fixture headers.
TITAN_TEST_C_INPUTS_support.common := spec/stdlib/titan/support/common.h
TITAN_TEST_C_INPUTS_fs.test_support := spec/stdlib/titan/fs/fixture_support.h
TITAN_TEST_C_INPUTS_io.test_support := spec/stdlib/titan/io/print_capture.h
TITAN_TEST_C_INPUTS_lua.test_support := spec/stdlib/titan/lua/source_fixture.h
TITAN_TEST_C_INPUTS_lua.handle_transfer_fixture := spec/stdlib/titan/lua/handle_transfer_fixture.h
TITAN_TEST_C_INPUTS_os.test_support := spec/stdlib/titan/os/time_support.h
TITAN_TEST_C_INPUTS_os.process_tests = $(TITAN_TEST_BUILD_DIR)/uv_coverage_pty.h
TITAN_TEST_C_INPUTS_reflect.tests := spec/stdlib/titan/reflect/reflection_recursive.h
TITAN_TEST_C_INPUTS_protobuf.tests := spec/stdlib/titan/protobuf/protobuf_fixture.h
TITAN_TEST_C_INPUTS_async.tests = $(TITAN_TEST_BUILD_DIR)/async_foreign_work.h \
	spec/stdlib/titan/async/tests/async_stack_probe.h \
	spec/stdlib/titan/async/tests/receiver_probe.h
TITAN_TEST_C_INPUTS_uv.runtime_tests = $(TITAN_TEST_BUILD_DIR)/uv_stdio_probe.h
TITAN_TEST_C_INPUTS_uv.public_tests = $(TITAN_TEST_BUILD_DIR)/uv_coverage_threads.h $(TITAN_TEST_BUILD_DIR)/uv_coverage_pty.h \
	spec/stdlib/titan/uv/public_tests/abandon_process_probe.h
TITAN_TEST_C_INPUTS_lua.tests = $(TITAN_TEST_BUILD_DIR)/uv_stdio_probe.h $(TITAN_TEST_BUILD_DIR)/async_foreign_work.h

TITAN_TEST_SOURCES_websocket.tests := spec/stdlib/titan/websocket/tests/tests.titan \
	spec/stdlib/titan/websocket/tests/raw_peer.titan \
	spec/stdlib/titan/websocket/tests/fixtures.titan \
	spec/stdlib/titan/websocket/tests/messages_test.titan \
	spec/stdlib/titan/websocket/tests/protocol_test.titan \
	spec/stdlib/titan/websocket/tests/opening_test.titan \
	spec/stdlib/titan/websocket/tests/lifecycle_test.titan \
	spec/stdlib/titan/websocket/tests/ownership_test.titan \
	spec/stdlib/titan/websocket/tests/backpressure.titan \
	spec/stdlib/titan/websocket/tests/backpressure_test.titan \
	spec/stdlib/titan/websocket/tests/transfer_test.titan \
	spec/stdlib/titan/websocket/tests/discard_transfer_test.titan
TITAN_TEST_IMPORTS_websocket.tests := support.async support.common support.runtime
TITAN_TEST_C_INPUTS_websocket.tests := spec/stdlib/titan/websocket/tests/pressure-native.h
