const std = @import("std");
const os = @import("std").os;
const io = @import("std").io;

const VMIN = 6; // TODO: where is this?
const VTIME = 5; // TODO: where is this?
var orig_termios: os.termios = undefined;

const NoLine = enum {
    Ctrl_d,
    Ctrl_c,
};

const ReadType = enum { line, no_line };
const Read = union(ReadType) {
    line: []u8,
    no_line: NoLine,
};

const InputType = enum { edit_more, read };

const Input = union(InputType) {
    edit_more: u8,
    read: Read,
};

const Zigline = struct {
    // struct linenoiseState {
    //     int in_completion;  /* The user pressed TAB and we are now in completion
    //                          * mode, so input is handled by completeLine(). */
    //     size_t completion_idx; /* Index of next completion to propose. */
    //-----int ifd;            /* Terminal stdin file descriptor. */
    //-----int ofd;            /* Terminal stdout file descriptor. */
    //-----char *buf;          /* Edited line buffer. */
    //-----size_t buflen;      /* Edited line buffer size. */
    //     const char *prompt; /* Prompt to display. */
    //     size_t plen;        /* Prompt length. */
    //-----pos;         /* Current cursor position. */
    //     size_t oldpos;      /* Previous refresh cursor position. */
    //-----len;         /* Current edited line length. */
    //     size_t cols;        /* Number of columns in terminal. */
    //     size_t oldrows;     /* Rows used by last refrehsed line (multiline mode) */
    //     int history_index;  /* The history index we are currently editing. */
    // };

    pub fn init(in: std.fs.File, out: std.fs.File, allocator: std.mem.Allocator) !Zigline {
        var res = Zigline{
            .in = in,
            .out = out,
            .alloc = allocator,
            .lbuf = std.ArrayList(u8).init(allocator),
            .hist = std.ArrayList([]const u8).init(allocator),
            .pos = 0,
        };
        var bw = std.io.bufferedWriter(out.writer());
        const stdout_writer = bw.writer();
        try enableRawMode(os.STDIN_FILENO);
        try res.refreshLine(stdout_writer);
        return res;
    }

    pub fn deinit(self: *Zigline) !void {
        _ = &self;
        try disableRawMode(os.STDIN_FILENO);
    }

    in: std.fs.File,
    out: std.fs.File,
    alloc: std.mem.Allocator,
    lbuf: std.ArrayList(u8),
    hist: std.ArrayList([]const u8),
    pos: usize,

    fn readchar(self: *Zigline) !u8 {
        var cbuf: [1]u8 = undefined;
        const read = try self.in.reader().read(&cbuf);
        if (read < 1) {
            return Error.Read;
        }
        return cbuf[0];
    }

    fn editInsert(self: *Zigline, c: u8) !void {
        try self.lbuf.append(c);
        self.pos += 1;
    }

    fn refreshLine(self: *Zigline, writer: anytype) !void {
        //TODO: maskmode  while (len--) abAppend(&ab,"*",1);
        if (self.pos > 0) {
            try std.fmt.format(writer, "\r{s}\x1b[0K\r\x1b[{d}C", .{ self.lbuf.items, self.pos });
        } else {
            try std.fmt.format(writer, "\r{s}\x1b[0K\r", .{self.lbuf.items});
        }
    }

    fn editBackspace(self: *Zigline) !void {
        if (self.pos > 0 and self.lbuf.items.len > 0) {
            const from: usize = self.pos - 1;
            const to: usize = self.lbuf.items.len - 1;
            for (from..to) |i| {
                self.lbuf.items[i] = self.lbuf.items[i + 1];
            }
            _ = self.lbuf.pop();
            self.pos -= 1;
        }
    }

    pub fn readline(self: *Zigline) !Read {
        while (true) {
            const read = try self.readInput();
            switch (read) {
                .edit_more => continue,
                .read => |r| return r,
            }
        }
    }

    pub fn readInput(self: *Zigline) !Input {
        var bw = std.io.bufferedWriter(self.out.writer());
        const stdout_writer = bw.writer();
        var res: Input = Input{ .edit_more = 0 };
        const c: u8 = try self.readchar();

        switch (c) {
            @intFromEnum(KeyAction.ENTER) => {
                const resline = try self.alloc.dupe(u8, self.lbuf.items);
                res = Input{ .read = Read{ .line = resline } };
                if (self.lbuf.items.len > 0) {
                    //const tmp: []const u8 = self.lbuf.items;
                    //try self.hist.append(tmp);
                    //self.lbuf = std.ArrayList(u8).init(self.alloc);
                    self.lbuf.clearRetainingCapacity();
                    self.pos = 0;
                }
            },
            @intFromEnum(KeyAction.CTRL_D) => res = Input{ .read = Read{ .no_line = NoLine.Ctrl_d } },
            @intFromEnum(KeyAction.CTRL_C) => res = Input{ .read = Read{ .no_line = NoLine.Ctrl_c } },
            @intFromEnum(KeyAction.BACKSPACE) => {
                try self.editBackspace();
            },
            @intFromEnum(KeyAction.CTRL_A) => try stdout_writer.print("Ctrl A", .{}),
            @intFromEnum(KeyAction.CTRL_E) => try stdout_writer.print("Ctrl E", .{}),
            @intFromEnum(KeyAction.ESC) => {
                const s0 = try self.readchar();
                const s1 = try self.readchar();
                switch (s0) {
                    '[' => {
                        switch (s1) {
                            '0'...'9' => {
                                const s2 = try self.readchar();
                                if (s2 == '~') {
                                    switch (s1) {
                                        '3' => try stdout_writer.print("Del", .{}),
                                        else => try stdout_writer.print("`Esc[N?~`", .{}),
                                    }
                                }
                            },
                            else => {
                                switch (s1) {
                                    'A' => try stdout_writer.print("Up", .{}),
                                    'B' => try stdout_writer.print("Down", .{}),
                                    'C' => try stdout_writer.print("Right", .{}),
                                    'D' => try stdout_writer.print("Left", .{}),
                                    'H' => try stdout_writer.print("Home", .{}), //TODO: check
                                    'F' => try stdout_writer.print("End", .{}), //TODO: check
                                    else => try stdout_writer.print("`Esc[?`", .{}),
                                }
                            },
                        }
                    },
                    'O' => {
                        switch (s1) {
                            'H' => try stdout_writer.print("Home", .{}),
                            'F' => try stdout_writer.print("End", .{}),
                            else => try stdout_writer.print("`EscO?`", .{}),
                        }
                    },
                    else => {},
                }
            },
            else => try self.editInsert(c),
        }
        try self.refreshLine(stdout_writer);
        try bw.flush(); // don't forget to flush!
        return res;
    }

    pub fn addHistory(self: *Zigline, line: []u8) !void {
        try self.hist.append(line);
    }
};

const KeyAction = enum(u8) {
    KEY_NULL = 0, // NULL
    CTRL_A = 1, // Ctrl+a
    CTRL_B = 2, // Ctrl-b
    CTRL_C = 3, // Ctrl-c
    CTRL_D = 4, // Ctrl-d
    CTRL_E = 5, // Ctrl-e
    CTRL_F = 6, // Ctrl-f
    CTRL_H = 8, // Ctrl-h
    TAB = 9, // Tab
    CTRL_K = 11, // Ctrl+k
    CTRL_L = 12, // Ctrl+l
    ENTER = 13, // Enter
    CTRL_N = 14, // Ctrl-n
    CTRL_P = 16, // Ctrl-p
    CTRL_T = 20, // Ctrl-t
    CTRL_U = 21, // Ctrl+u
    CTRL_W = 23, // Ctrl+w
    ESC = 27, // Escape
    BACKSPACE = 127, // Backspace
};

fn disableRawMode(fd: i32) !void {
    try os.tcsetattr(fd, os.TCSA.FLUSH, orig_termios);
}

fn enableRawMode(fd: i32) !void {
    var raw: os.termios = undefined;

    if (!os.isatty(os.STDIN_FILENO)) { //TODO: raise
        return;
    }

    orig_termios = try os.tcgetattr(fd);

    raw = orig_termios; // modify the original mode
    // input modes: no break, no CR to NL, no parity check, no strip char,
    // no start/stop output control.
    raw.iflag &= ~(os.linux.BRKINT | os.linux.ICRNL | os.linux.INPCK | os.linux.ISTRIP | os.linux.IXON);
    // output modes - disable post processing
    raw.oflag &= ~(os.linux.OPOST);
    // control modes - set 8 bit chars
    raw.cflag |= (os.linux.CS8);
    // local modes - choing off, canonical off, no extended functions, no
    // signal chars (^Z,^C)
    raw.lflag &= ~(os.linux.ECHO | os.linux.ICANON | os.linux.IEXTEN | os.linux.ISIG);
    // control chars - set return condition: min number of bytes and
    // timer. We want read to return every single byte, without timeout.
    raw.cc[VMIN] = 1;
    raw.cc[VTIME] = 0; // 1 byte, no timer

    // put terminal in raw mode after flushing
    try os.tcsetattr(fd, os.TCSA.FLUSH, raw);
}

const Error = error{ Read, Write };

pub fn main() !void {
    //allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    //stdout
    const stdout = std.io.getStdOut();
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();
    //stdin
    const stdin = std.io.getStdIn(); //.reader();

    try stdout_writer.print("Zigline :) Exit with C-c\n", .{});
    try bw.flush(); // don't forget to flush!

    var zigline = try Zigline.init(stdin, stdout, allocator);
    while (true) {
        const read = try zigline.readline();
        switch (read) {
            .line => |ln| {
                if (ln.len > 0) {
                    try zigline.addHistory(ln);
                }
            },
            .no_line => break,
        }
    }

    try zigline.deinit();

    for (zigline.hist.items, 1..) |ln, i| {
        std.debug.print("line {d}: `{s}'\n", .{ i, ln });
    }
}
