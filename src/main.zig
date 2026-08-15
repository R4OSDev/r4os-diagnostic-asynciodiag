const r4os = @import("r4os");

const write_path_text = "C:\\TEMP\\ASYNIOD.TXT";
const stream_path_text = "C:\\TEMP\\ASYNIOS.TXT";
const payload = "async-r4sys-io-v1";
const stream_a = "stream-";
const stream_b = "completion";
const task_churn_requests: u32 = 512;
const kill_wait_arg = "/KILLWAIT";
const kill_wait_threads_arg = "/KILLWAITTHREADS";
const retire_retry_arg = "/RETIRERETRY";
const retire_retry_path = "C:\\TEMP\\ASYNIOR.TXT";
const retire_retry_payload = "async-retire-retry";
const kill_wait_op: u16 = 0x0597;
var lifecycle_sys: ?r4os.r4sys.Context = null;

pub fn r4_app_main(app: *r4os.App) i32 {
    var sys = app.system();
    if (hasArg(sys.argsRaw(), retire_retry_arg)) return runRetireRetry(&sys);
    if (hasArg(sys.argsRaw(), kill_wait_threads_arg)) {
        const handle = argU32After(sys.argsRaw(), kill_wait_threads_arg) orelse
            return fail(&sys, "ASYNIOD killwaitthreads handle missing");
        return runKillWaitWithThreads(&sys, handle);
    }
    if (hasArg(sys.argsRaw(), kill_wait_arg)) {
        const handle = argU32After(sys.argsRaw(), kill_wait_arg) orelse
            return fail(&sys, "ASYNIOD killwait handle missing");
        return runKillWait(&sys, handle);
    }
    const resources = app.resources();
    const write_path = r4os.FilePath.parse(write_path_text) catch return fail(&sys, "ASYNIOD write path invalid");
    const stream_path = r4os.FilePath.parse(stream_path_text) catch return fail(&sys, "ASYNIOD stream path invalid");

    sys.println("ASYNIOD");
    if (!resources.available()) return fail(&sys, "ASYNIOD resource facade missing");
    if (!writeAndVerify(&sys, &resources, write_path.asZ())) return fail(&sys, "ASYNIOD write/read failed");
    if (!streamAndVerify(&resources, stream_path.asZ())) return fail(&sys, "ASYNIOD stream failed");
    if (!stressRequests(&sys, &resources, write_path.asZ())) return fail(&sys, "ASYNIOD stress leaked slots");

    sys.println("ASYNIOD result: OK");
    return 0;
}

fn runRetireRetry(sys: *r4os.r4sys.Context) i32 {
    sys.println("ASYNIOD retire retry");
    const written = sys.fileWrite(retire_retry_path, retire_retry_payload);
    if (written != @as(i32, @intCast(retire_retry_payload.len)))
        return fail(sys, "ASYNIOD retire retry write failed");
    var verify: [32]u8 = .{0} ** 32;
    const read = sys.fileRead(retire_retry_path, verify[0..]);
    if (read != written or !equal(verify[0..retire_retry_payload.len], retire_retry_payload))
        return fail(sys, "ASYNIOD retire retry verify failed");
    sys.println("ASYNIOD retire retry: OK");
    sys.println("ASYNIOD result: OK");
    return 0;
}

fn runKillWaitWithThreads(sys: *r4os.r4sys.Context, service_handle: u32) i32 {
    lifecycle_sys = sys.*;
    var index: u32 = 0;
    while (index < 3) : (index += 1) {
        var handle: r4os.abi.ProgramJoinHandle = .{};
        if (sys.threadCreateHandle(lifecycleWorker, index, 0, 0, &handle) != r4os.abi.thread_ok or !validJoinHandle(handle))
            return fail(sys, "ASYNIOD lifecycle worker create failed");
        // Intentionally do not join: /KILLWAITTHREADS validates that killing
        // the owning program tears down exactly these three live child threads
        // together with the blocked async request and the owner instance.
    }
    sys.println("ASYNIOD lifecycle workers=3 ready=OK");
    return runKillWait(sys, service_handle);
}

fn validJoinHandle(handle: r4os.abi.ProgramJoinHandle) bool {
    return handle.thread_id != 0 and
        handle.instance_id != 0 and
        handle.thread_generation != 0 and
        handle.instance_generation != 0 and
        handle.reserved == 0;
}

fn lifecycleWorker(_: u64) callconv(.c) i32 {
    var sys = lifecycle_sys orelse return 71;
    while (true) sys.sleepTicks(1);
}

fn runKillWait(sys: *r4os.r4sys.Context, service_handle: u32) i32 {
    sys.println("ASYNIOD killwait begin");
    if (!sys.hasFn("io_service_call") or !sys.hasFn("io_wait") or !sys.hasFn("io_close"))
        return fail(sys, "ASYNIOD killwait async service API missing");

    var response_header: r4os.abi.ServiceMessageHeader = .{};
    var response: [1]u8 = .{0};
    var request_id: u32 = 0;
    const submit = sys.ioServiceCall(
        service_handle,
        kill_wait_op,
        "WAIT",
        &response_header,
        response[0..],
        r4os.abi.io_wait_forever,
        0,
        &request_id,
    );
    if (submit != r4os.abi.io_ok or request_id == 0)
        return fail(sys, "ASYNIOD killwait submit failed");

    sys.write("ASYNIOD killwait submitted request=");
    sys.printU64(@intCast(request_id));
    sys.println("");

    var io_info: r4os.abi.ProgramIoInfo = .{};
    const waited = sys.ioWait(request_id, r4os.abi.io_wait_forever, &io_info);
    _ = sys.ioClose(request_id);
    sys.write("ASYNIOD killwait unexpected wake rc=");
    sys.printI32(waited);
    sys.println("");
    return fail(sys, "ASYNIOD killwait returned before kill");
}

fn writeAndVerify(sys: *r4os.r4sys.Context, resources: *const r4os.Resources, path: r4os.app_storage.PathZ) bool {
    var write_request = switch (resources.asyncWrite(path, payload, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!write_request.buffersHeld() or write_request.releaseBuffers() != r4os.abi.err_buffer_in_use) return false;
    if (!waitExpect(&write_request, @intCast(payload.len))) return false;
    if (write_request.close() != r4os.abi.io_ok or write_request.buffersHeld()) return false;
    if (write_request.close() != r4os.abi.err_closed) return false;

    var buffer: [64]u8 = .{0} ** 64;
    var read_request = switch (resources.asyncRead(path, buffer[0..], 0)) {
        .request => |request| request,
        .failure => return false,
    };
    const status = switch (read_request.status()) {
        .value => |info| info,
        .failure => return false,
    };
    if (status.request_id != read_request.raw or status.kind != r4os.abi.io_kind_file_read) return false;
    if (!waitExpect(&read_request, @intCast(payload.len))) return false;
    if (read_request.releaseBuffers() != r4os.abi.err_buffer_in_use) return false;
    if (read_request.close() != r4os.abi.io_ok or read_request.releaseBuffers() != r4os.abi.io_ok) return false;
    if (!equal(buffer[0..payload.len], payload)) return false;
    _ = sys;
    return true;
}

fn streamAndVerify(resources: *const r4os.Resources, path: r4os.app_storage.PathZ) bool {
    var begin = switch (resources.asyncStreamBegin(path, r4os.abi.file_stream_open_replace)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&begin, r4os.abi.file_stream_result_ok) or begin.close() != r4os.abi.io_ok) return false;

    var first = switch (resources.asyncStreamWrite(path, 0, stream_a, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&first, @intCast(stream_a.len)) or first.close() != r4os.abi.io_ok) return false;

    var second = switch (resources.asyncStreamWrite(path, stream_a.len, stream_b, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&second, @intCast(stream_b.len)) or second.close() != r4os.abi.io_ok) return false;

    const expected_size = stream_a.len + stream_b.len;
    var finish = switch (resources.asyncStreamFinish(path, expected_size, 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&finish, r4os.abi.file_stream_result_ok) or finish.close() != r4os.abi.io_ok) return false;

    var buffer: [64]u8 = .{0} ** 64;
    var read_request = switch (resources.asyncRead(path, buffer[0..], 0)) {
        .request => |request| request,
        .failure => return false,
    };
    if (!waitExpect(&read_request, @intCast(expected_size)) or read_request.close() != r4os.abi.io_ok) return false;
    return equal(buffer[0..stream_a.len], stream_a) and equal(buffer[stream_a.len..expected_size], stream_b);
}

fn stressRequests(sys: *r4os.r4sys.Context, resources: *const r4os.Resources, path: r4os.app_storage.PathZ) bool {
    var index: u32 = 0;
    while (index < task_churn_requests) : (index += 1) {
        var buffer: [64]u8 = .{0} ** 64;
        var request = switch (resources.asyncRead(path, buffer[0..], 0)) {
            .request => |value| value,
            .failure => return false,
        };
        if (!waitExpect(&request, @intCast(payload.len)) or request.close() != r4os.abi.io_ok) return false;
    }
    sys.write("ASYNIOD task churn: OK requests=");
    sys.printU64(task_churn_requests);
    sys.println("");
    return true;
}

fn waitExpect(request: *r4os.IoRequest, expected: i32) bool {
    const info = switch (request.wait(r4os.time_contract.timeoutForever())) {
        .completed => |value| value,
        else => return false,
    };
    return info.result == expected and info.state == r4os.abi.io_state_completed;
}

fn equal(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (left != right) return false;
    return true;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn argU32After(args: [*:0]const u8, wanted: []const u8) ?u32 {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (!equalsIgnoreCase(args[start..offset], wanted)) continue;
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        var value: u32 = 0;
        var digits: u32 = 0;
        while (offset < 256 and args[offset] >= '0' and args[offset] <= '9') : (offset += 1) {
            const digit: u32 = args[offset] - '0';
            if (value > (0xFFFF_FFFF - digit) / 10) return null;
            value = value * 10 + digit;
            digits += 1;
        }
        if (digits == 0 or value == 0) return null;
        if (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') return null;
        return value;
    }
    return null;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (upper(left) != upper(right)) return false;
    return true;
}

fn upper(ch: u8) u8 {
    if (ch >= 'a' and ch <= 'z') return ch - ('a' - 'A');
    return ch;
}

fn fail(sys: *r4os.r4sys.Context, msg: []const u8) i32 {
    sys.println(msg);
    sys.println("ASYNIOD result: FAILED");
    return 1;
}
