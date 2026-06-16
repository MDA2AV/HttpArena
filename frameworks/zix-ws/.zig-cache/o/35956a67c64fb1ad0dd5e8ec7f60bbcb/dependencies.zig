pub const packages = struct {
    pub const @"vendor/zix" = struct {
        pub const build_root = "/mnt/256a1/repo/HttpArena/frameworks/zix-ws/vendor/zix";
        pub const deps: []const struct { []const u8, []const u8 } = &.{};
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zix", "vendor/zix" },
};
