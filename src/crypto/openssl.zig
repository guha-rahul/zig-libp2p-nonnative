const std = @import("std");
const b58 = @import("../multibase/b58.zig");
const protobuf = @import("../util/protobuf.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const no_padding_encoding = @import("../crypto.zig").no_padding_encoding;

const c = @cImport({
    // See https://github.com/ziglang/zig/issues/515
    // @cDefine("_NO_CRT_STDIO_INLINE", "1");
    @cInclude("openssl/asn1.h");
    @cInclude("openssl/evp.h");
    @cInclude("openssl/ec.h");
    @cInclude("openssl/pem.h");
    @cInclude("openssl/x509.h");
    @cInclude("openssl/err.h");
    @cInclude("openssl/pkcs12.h");
});

// https://github.com/libp2p/specs/blob/master/tls/tls.md#libp2p-public-key-extension
const libp2p_tls_handshake_prefix = "libp2p-tls-handshake:";
pub const libp2p_extension_oid = "1.3.6.1.4.1.53594.1.1";

pub const PKCS12 = struct {
    bundle: *c.PKCS12,
    pub fn init(kp: OpenSSLKey.ED25519KeyPair, x509: X509) !PKCS12 {
        var pkcs12bundle = c.PKCS12_create(null, // certbundle access password
            "libp2p", // friendly certname
            kp.key, // the certificate private key
            x509.inner, // the main certificate
            null, // stack of CA cert chain
            0, // default
            0, // default
            0, // default
            0, // default
            0 // default
        );

        if (pkcs12bundle == null) {
            return error.pkcs12Failed;
        }
        return PKCS12{ .bundle = pkcs12bundle.? };
    }

    pub fn read(self: PKCS12, buffer: []u8) !usize {
        const len = c.i2d_PKCS12(self.bundle, null);
        if (len <= 0) {
            return error.PKCS12SerFailed;
        }

        if (len > buffer.len) {
            return error.BufferTooSmall;
        }

        var buf_ptr: ?[*]u8 = buffer.ptr;
        const bytes_written = c.i2d_PKCS12(self.bundle, &buf_ptr);
        if (bytes_written <= 0) {
            return error.PKCS12SerFailed;
        }

        return @intCast(usize, len);
    }

    pub fn initFromDer(buffer: []u8) !PKCS12 {
        var buf_btr: ?[*]u8 = buffer.ptr;
        var pkcs12bundle = c.d2i_PKCS12(null, &buf_btr, @intCast(c_long, buffer.len));
        if (pkcs12bundle == null) {
            return error.PKCS12DeserFailed;
        }
        return PKCS12{ .bundle = pkcs12bundle.? };
    }

    pub fn deinit(self: PKCS12) void {
        c.PKCS12_free(self.bundle);
    }
};

pub const X509 = struct {
    inner: *c.X509,
    libp2p_extension: ?*c.X509_EXTENSION = null,

    pub fn init(kp: OpenSSLKey.ED25519KeyPair, libp2p_extension_data: ?[]const u8) !X509 {
        // Copied mostly from: https://stackoverflow.com/questions/256405/programmatically-create-x509-certificate-using-openssl
        const pkey = kp.key;
        var x509: ?*c.X509 = null;
        x509 = c.X509_new();
        if (x509 == null) {
            return error.genX509Failed;
        }
        _ = c.X509_set_version(x509, c.X509_VERSION_3);

        // Set cert's pubkey
        if (c.X509_set_pubkey(x509, pkey) == 0) {
            return error.setPubKeyFailed;
        }

        // Set serial number (random)
        var bn = c.BN_new();
        defer c.BN_free(bn);
        if (c.BN_pseudo_rand(bn, 64, 0, 0) == 0) {
            return error.FailedToGenRandSN;
        }

        var rand_int = c.ASN1_INTEGER_new();
        _ = c.BN_to_ASN1_INTEGER(bn, rand_int);

        if (c.X509_set_serialNumber(x509, rand_int) == 0) {
            c.ASN1_INTEGER_free(rand_int);
            return error.FailedToAddSN;
        }

        _ = c.X509_gmtime_adj(c.X509_get_notBefore(x509), 0);
        _ = c.X509_gmtime_adj(c.X509_get_notAfter(x509), 60 * 60 * 24 * 365);

        var name: ?*c.X509_NAME = null;
        name = c.X509_get_subject_name(x509);

        // Self signed. Issuer == subject
        if (c.X509_set_issuer_name(x509, name) == 0) {
            return error.setIssuerFailed;
        }
        _ = c.X509_NAME_add_entry_by_txt(name, "C", c.MBSTRING_ASC, "US", -1, -1, 0);
        _ = c.X509_NAME_add_entry_by_txt(name, "O", c.MBSTRING_ASC, "libp2p", -1, -1, 0);
        _ = c.X509_NAME_add_entry_by_txt(name, "CN", c.MBSTRING_ASC, "libp2p", -1, -1, 0);

        //check
        var x509_wrapper = X509{ .inner = x509.? };
        if (libp2p_extension_data != null) {
            try x509_wrapper.insertLibp2pExtension(libp2p_extension_data.?);
        }

        // Null since ed25519 doesn't support digest here
        if (c.X509_sign(x509, pkey, null) == 0) {
            var err = c.ERR_get_error();
            var err_str = [_]u8{0} ** 1024;
            while (err != 0) {
                c.ERR_error_string_n(err, err_str[0..], 1024);
                std.log.debug("err code {}.\n{s}\n", .{ err, err_str });
                err = c.ERR_get_error();
            }

            return error.signFailed;
        }

        if (x509 == null) {
            return error.genX509Failed;
        }

        return x509_wrapper;
    }

    pub fn deinit(self: X509) void {
        c.X509_free(self.inner);
        if (self.libp2p_extension != null) {
            // Do I need to do this here? unclear
            c.X509_EXTENSION_free(self.libp2p_extension);
        }
    }

    pub fn initFromDer(buffer: []u8) !X509 {
        var buf_btr: ?[*]u8 = buffer.ptr;
        var inner = c.d2i_X509(null, &buf_btr, @intCast(c_long, buffer.len));
        if (inner == null) {
            return error.DeserFailed;
        }

        return X509{ .inner = inner.? };
    }

    // Returns a slice to internal data. Caller should not attempt to free the slice.
    // https://www.openssl.org/docs/man1.1.1/man3/X509_EXTENSION_get_object.html
    pub fn getExtensionData(self: X509, oid: []const u8) ![]u8 {
        var obj = c.OBJ_txt2obj(oid.ptr, 1);
        defer c.ASN1_OBJECT_free(obj);
        var ext_loc = c.X509_get_ext_by_OBJ(self.inner, obj, -1);
        if (ext_loc == -1) {
            return error.ExtensionNotFound;
        }

        var ext = c.X509_get_ext(self.inner, ext_loc);
        assert(ext != null);

        var os = c.X509_EXTENSION_get_data(ext);
        assert(os != null);

        return os.*.data[0..@intCast(usize, os.*.length)];
    }

    pub fn getPubKey(self: X509) !OpenSSLKey {
        var inner_key = c.X509_get_pubkey(self.inner);
        if (inner_key == null) {
            return error.NoPubKey;
        }

        switch (c.EVP_PKEY_base_id(inner_key)) {
            c.EVP_PKEY_ED25519 => {
                return OpenSSLKey{ .Ed25519 = .{ .key = inner_key.? } };
            },
            c.EVP_PKEY_EC => {
                return OpenSSLKey{ .ECDSA = .{ .key = inner_key.? } };
            },
            else => {
                std.log.debug("Key type is {}\n", .{c.EVP_PKEY_base_id(inner_key)});
                return error.WrongPubKey;
            },
        }
    }

    pub fn insertLibp2pExtension(self: *X509, extension_data: []const u8) !void {
        var os = c.ASN1_OCTET_STRING_new();
        defer c.ASN1_OCTET_STRING_free(os);
        if (c.ASN1_OCTET_STRING_set(os, extension_data.ptr, @intCast(c_int, @intCast(u32, extension_data.len))) == 0) {
            return error.ASN1_OCTET_STRING_set_failed;
        }

        var obj = c.OBJ_txt2obj(libp2p_extension_oid, 1);
        defer c.ASN1_OBJECT_free(obj);

        var ex = c.X509_EXTENSION_create_by_OBJ(null, obj, 0, os);
        if (ex == null) {
            @panic("Failed to create extension");
        }

        if (self.libp2p_extension != null) {
            @panic("Already have a libp2p extension!");
        }
        _ = c.X509_EXTENSION_set_critical(ex, 1);

        if (c.X509_add_ext(self.inner, ex, -1) != 1) {
            return error.X509_add_ext_failed;
        }

        self.libp2p_extension = ex;
    }
};

pub const KeyType = enum(u8) {
    RSA = 0,
    Ed25519 = 1,
    Secp256k1 = 2,
    ECDSA = 3,
};

pub const PeerID = union(KeyType) {
    RSA: struct { pub_key_hash: [32]u8 }, // sha256 hash
    Ed25519: struct {
        pub_key_bytes: [Key.Ed25519.key_len]u8,

        pub fn toString(self: @This()) [OpenSSLKey.ED25519KeyPair.PublicKey.PeerIDStrLen]u8 {
            var bytes = (([_]u8{
                // cidv1
                0x01,
                // libp2p-key
                0x72,
                // multihash identity
                0x00,
                @intCast(u8, OpenSSLKey.ED25519KeyPair.PublicKey.pb_encoded_len),
            }) ++ [_]u8{0} ** OpenSSLKey.ED25519KeyPair.PublicKey.pb_encoded_len);

            // The key should be written starting at the 5th byte
            _ = OpenSSLKey.ED25519KeyPair.PublicKey.serializePbFromRaw(self.pub_key_bytes, bytes[4..]);

            // +1 for the multibase prefix
            const b32_size = comptime no_padding_encoding.encodeLen(bytes.len) + 1;
            var buf = [_]u8{0} ** b32_size;
            // Multibase "b" base32
            buf[0] = 'b';

            _ = no_padding_encoding.encode(buf[1..], bytes[0..]);

            return buf;
        }

        pub fn toLegacyString(self: @This(), allocator: std.mem.Allocator) ![]u8 {
            var bytes = (([_]u8{
                // multihash identity
                0x00,
                @intCast(u8, OpenSSLKey.ED25519KeyPair.PublicKey.pb_encoded_len),
            }) ++ [_]u8{0} ** OpenSSLKey.ED25519KeyPair.PublicKey.pb_encoded_len);

            // The key should be written starting at the 2nd byte
            _ = OpenSSLKey.ED25519KeyPair.PublicKey.serializePbFromRaw(self.pub_key_bytes, bytes[2..]);

            return b58.encode(allocator, &bytes);
        }
    },

    Secp256k1: struct { pub_key_bytes: [32]u8 },
    ECDSA: struct {
        pub_key_bytes: [64]u8,

        pub fn toString(self: @This()) [OpenSSLKey.ECDSAKeyPair.PublicKey.PeerIDStrLen]u8 {
            var bytes = (([_]u8{
                // cidv1
                0x01,
                // libp2p-key
                0x72,
                // multihash identity
                0x00,
                @intCast(u8, OpenSSLKey.ECDSAKeyPair.PublicKey.pb_encoded_len),
            }) ++ [_]u8{0} ** OpenSSLKey.ECDSAKeyPair.PublicKey.pb_encoded_len);

            // The key should be written starting at the 5th byte
            _ = OpenSSLKey.ECDSAKeyPair.PublicKey.serializePbFromRaw(self.pub_key_bytes, bytes[4..]);

            // +1 for the multibase prefix
            const b32_size = comptime no_padding_encoding.encodeLen(bytes.len) + 1;
            var buf = [_]u8{0} ** b32_size;
            // Multibase "b" base32
            buf[0] = 'b';

            _ = no_padding_encoding.encode(buf[1..], bytes[0..]);

            return buf;
        }

        pub fn toLegacyString(self: @This(), allocator: std.mem.Allocator) ![]u8 {
            var bytes = (([_]u8{
                // multihash identity
                0x00,
                @intCast(u8, OpenSSLKey.ECDSAKeyPair.PublicKey.pb_encoded_len),
            }) ++ [_]u8{0} ** OpenSSLKey.ECDSAKeyPair.PublicKey.pb_encoded_len);

            // The key should be written starting at the 2nd byte
            _ = OpenSSLKey.ECDSAKeyPair.PublicKey.serializePbFromRaw(self.pub_key_bytes, bytes[2..]);

            return b58.encode(allocator, &bytes);
        }
    },

    pub fn equal(self: PeerID, other: PeerID) bool {
        if (@enumToInt(self) != @enumToInt(other)) {
            return false;
        }
        switch (self) {
            .RSA => {
                return false;
            },
            .Ed25519 => {
                return std.mem.eql(u8, self.Ed25519.pub_key_bytes[0..], other.Ed25519.pub_key_bytes[0..]);
            },
            .ECDSA => {
                return std.mem.eql(u8, self.ECDSA.pub_key_bytes[0..], other.ECDSA.pub_key_bytes[0..]);
            },
            else => {
                @panic("TODO");
            },
        }
    }

    pub fn toString(self: @This(), allocator: Allocator) ![]u8 {
        switch (self) {
            .Ed25519 => {
                const peer_id = self.Ed25519.toString();
                const peer_id_copy = try allocator.alloc(u8, peer_id.len);
                std.mem.copy(u8, peer_id_copy, peer_id[0..]);
                return peer_id_copy;
            },
            .ECDSA => {
                const peer_id = self.ECDSA.toString();
                const peer_id_copy = try allocator.alloc(u8, peer_id.len);
                std.mem.copy(u8, peer_id_copy, peer_id[0..]);
                return peer_id_copy;
            },
            else => {
                return error.UnsupportedKeyType;
            },
        }
    }
};

pub const OpenSSLKey = union(KeyType) {
    RSA: struct {},
    Secp256k1: struct {},
    Ed25519: ED25519KeyPair,
    ECDSA: ECDSAKeyPair,

    pub const ECDSAKeyPair = struct {
        key: *c.EVP_PKEY,
        const key_len = 64;
        const curve_name = "p256";

        pub const PublicKey = struct {
            key: *c.EVP_PKEY,
            const DER_encoded_len = key_len + 12;
            const pb_encoded_len = key_len + 4;
            const libp2p_extension_len = DER_encoded_len + libp2p_tls_handshake_prefix.len;
            const PeerIDStrLen = blk: {
                const bytes = ([_]u8{
                    // cidv1
                    0x01,
                    // libp2p-key
                    0x72,
                    // multihash identity
                    0x00,
                    @intCast(u8, pb_encoded_len),
                } ++ [_]u8{0} ** pb_encoded_len);

                // +1 for the multibase prefix
                const b32_size = no_padding_encoding.encodeLen(bytes.len) + 1;
                break :blk b32_size;
            };

            pub fn toPeerID(self: @This()) !PeerID {
                var peer = PeerID{ .ECDSA = .{ .pub_key_bytes = [_]u8{0} ** key_len } };

                // Get the EC_KEY from EVP_PKEY
                var ec_key = c.EVP_PKEY_get1_EC_KEY(self.key);
                if (ec_key == null) {
                    return error.GetECKeyFailed;
                }
                defer c.EC_KEY_free(ec_key);

                // Get the EC_POINT (public key)
                var ec_point = c.EC_KEY_get0_public_key(ec_key);
                if (ec_point == null) {
                    return error.GetECPointFailed;
                }

                // Get the EC_GROUP
                var ec_group = c.EC_KEY_get0_group(ec_key);
                if (ec_group == null) {
                    return error.GetECGroupFailed;
                }

                // Convert the EC_POINT to uncompressed binary form (65 bytes)
                var buf = [_]u8{0} ** 65;
                const point_len = c.EC_POINT_point2oct(ec_group, ec_point, c.POINT_CONVERSION_UNCOMPRESSED, &buf, 65, null);

                if (point_len != 65) {
                    return error.ECPointConversionFailed;
                }

                std.mem.copy(u8, peer.ECDSA.pub_key_bytes[0..], buf[1..65]);
                return peer;
            }

            fn libp2pExtension(self: @This()) [libp2p_extension_len]u8 {
                var out = [_]u8{0} ** libp2p_extension_len;
                std.mem.copy(u8, out[0..], libp2p_tls_handshake_prefix);

                var out_slice: []u8 = out[libp2p_tls_handshake_prefix.len..];
                var out_ptr: ?[*]u8 = out_slice.ptr;
                const len = c.i2d_PUBKEY(self.key, &out_ptr);
                std.debug.assert(len == DER_encoded_len);

                return out;
            }

            fn serializePb(self: @This(), out: []u8) !usize {
                assert(out.len >= pb_encoded_len);
                serializePbHeader(out);

                // Get the EC_KEY from EVP_PKEY
                var ec_key = c.EVP_PKEY_get1_EC_KEY(self.key);
                if (ec_key == null) {
                    return error.GetECKeyFailed;
                }
                defer c.EC_KEY_free(ec_key);

                // Get the EC_POINT (public key)
                var ec_point = c.EC_KEY_get0_public_key(ec_key);
                if (ec_point == null) {
                    return error.GetECPointFailed;
                }

                // Get the EC_GROUP
                var ec_group = c.EC_KEY_get0_group(ec_key);
                if (ec_group == null) {
                    return error.GetECGroupFailed;
                }

                // Convert the EC_POINT to uncompressed binary form (65 bytes)
                var buf = [_]u8{0} ** 65;
                const point_len = c.EC_POINT_point2oct(ec_group, ec_point, c.POINT_CONVERSION_UNCOMPRESSED, &buf, 65, null);

                if (point_len != 65) {
                    return error.ECPointConversionFailed;
                }

                var pub_key_out_slice = out[4..];
                std.mem.copy(u8, pub_key_out_slice[0..key_len], buf[1..65]);

                return pb_encoded_len;
            }

            fn serializePbHeader(out: []u8) void {
                assert(out.len >= (pb_encoded_len - key_len));
                out[0] = Key.pbFieldKey(1, 0);
                out[1] = @enumToInt(KeyType.ECDSA);

                out[2] = Key.pbFieldKey(2, 2);
                out[3] = key_len;
            }

            fn serializePbFromRaw(public_key: [key_len]u8, out: []u8) usize {
                assert(out.len >= pb_encoded_len);
                serializePbHeader(out);
                std.mem.copy(u8, out[4..], &public_key);
                return pb_encoded_len;
            }

            fn deinit(self: @This()) void {
                c.EVP_PKEY_free(self.key);
            }
        };

        pub const Signature = struct {
            sig: [Len]u8,
            actual_len: usize,

            const Len = 72;

            fn fromSlice(s: []const u8) !Signature {
                if (s.len > Len) {
                    return error.SignatureTooLong;
                }

                var self = Signature{ .sig = [_]u8{0} ** Len, .actual_len = s.len };
                std.mem.copy(u8, self.sig[0..s.len], s);
                return self;
            }

            fn verify(self: Signature, pub_key: ECDSAKeyPair.PublicKey, msg: []u8) !bool {
                var md_ctx = c.EVP_MD_CTX_new();
                defer c.EVP_MD_CTX_free(md_ctx);

                // Initialize with SHA256 digest
                if (c.EVP_DigestVerifyInit(md_ctx, null, c.EVP_sha256(), null, pub_key.key) == 0) {
                    return error.DigestVerifyInitFailed;
                }

                const err = c.EVP_DigestVerify(md_ctx, self.sig[0..self.actual_len].ptr, self.actual_len, msg.ptr, msg.len);

                switch (err) {
                    1 => {
                        return true;
                    },
                    0 => {
                        return false;
                    },
                    else => {
                        // For malformed signatures or other OpenSSL errors, treat as verification failure
                        return false;
                    },
                }
            }
        };

        pub fn new() !ECDSAKeyPair {
            // 1) create the EC key
            var ec_key = c.EC_KEY_new_by_curve_name(c.NID_X9_62_prime256v1);
            if (ec_key == null) {
                return error.ECKeyCreationFailed;
            }

            // Wrap error cleanup in a defer that checks whether we've already assigned:
            var assigned = false;
            defer if (!assigned) c.EC_KEY_free(ec_key);

            // 2) generate the keypair
            if (c.EC_KEY_generate_key(ec_key) != 1) {
                return error.KeyGenerationFailed;
            }

            c.EC_KEY_set_asn1_flag(ec_key, c.OPENSSL_EC_NAMED_CURVE);

            // 3) lift into EVP_PKEY
            const maybePkey = c.EVP_PKEY_new();
            if (maybePkey == null) {
                return error.EVPKeyCreationFailed;
            }
            if (c.EVP_PKEY_assign_EC_KEY(maybePkey.?, ec_key) != 1) {
                c.EVP_PKEY_free(maybePkey.?);
                return error.EVPKeyAssignFailed;
            }

            // Now we've handed off ec_key → pkey, disable the cleanup
            assigned = true;

            return ECDSAKeyPair{ .key = maybePkey.? };
        }

        pub fn deinit(self: ECDSAKeyPair) void {
            c.EVP_PKEY_free(self.key);
        }

        pub fn toPubKey(self: *ECDSAKeyPair) PublicKey {
            return PublicKey{ .key = self.key };
        }

        fn sign(self: ECDSAKeyPair, msg: []const u8) !Signature {
            var sig = Signature{ .sig = [_]u8{0} ** Signature.Len, .actual_len = 0 };
            var sig_len: usize = Signature.Len;

            var md_ctx = c.EVP_MD_CTX_new();
            if (md_ctx == null) {
                return error.MDContextCreationFailed;
            }
            defer c.EVP_MD_CTX_free(md_ctx);

            // Initialize with SHA256 digest
            if (c.EVP_DigestSignInit(md_ctx, null, c.EVP_sha256(), null, self.key) == 0) {
                return error.DigestSignInitFailed;
            }

            var sig_slice: []u8 = sig.sig[0..];
            if (c.EVP_DigestSign(md_ctx, sig_slice.ptr, &sig_len, msg.ptr, msg.len) == 0) {
                return error.DigestSignFailed;
            }

            sig.actual_len = sig_len;
            return sig;
        }

        fn signToDest(self: ECDSAKeyPair, msg: []u8, dest: []u8) !void {
            assert(dest.len >= Signature.Len);

            var sig_len: usize = Signature.Len;

            var md_ctx = c.EVP_MD_CTX_new();
            if (md_ctx == null) {
                return error.MDContextCreationFailed;
            }
            defer c.EVP_MD_CTX_free(md_ctx);

            // Initialize with SHA256 digest
            if (c.EVP_DigestSignInit(md_ctx, null, c.EVP_sha256(), null, self.key) == 0) {
                return error.DigestSignInitFailed;
            }

            if (c.EVP_DigestSign(md_ctx, dest.ptr, &sig_len, msg.ptr, msg.len) == 0) {
                return error.DigestSignFailed;
            }
        }
        /// Parse an EC private key from a DER‐encoded ECPrivateKey blob.
        pub fn fromDerPrivateKey(der: []const u8) !ECDSAKeyPair {
            var der_ptr: [*]const u8 = der.ptr;
            const in_ptr = @ptrCast([*c][*c]const u8, &der_ptr);
            var ec_key = c.d2i_ECPrivateKey(null, in_ptr, @intCast(c_long, der.len));
            if (ec_key == null) {
                return error.DerPrivKeyParseFailed;
            }

            // wrap into an EVP_PKEY so the rest of the API just works
            var pkey = c.EVP_PKEY_new();
            if (pkey == null) {
                c.EC_KEY_free(ec_key);
                return error.EVPKeyCreationFailed;
            }
            if (c.EVP_PKEY_assign_EC_KEY(pkey, ec_key) != 1) {
                c.EVP_PKEY_free(pkey);
                c.EC_KEY_free(ec_key);
                return error.EVPKeyAssignFailed;
            }

            return ECDSAKeyPair{ .key = pkey.? };
        }
    };

    pub const ED25519KeyPair = struct {
        key: *c.EVP_PKEY,

        const key_len = 32;

        pub const PublicKey = struct {
            key: *c.EVP_PKEY,

            const DER_encoded_len = 44;
            const pb_encoded_len = key_len + 4;
            const libp2p_extension_len = DER_encoded_len + libp2p_tls_handshake_prefix.len;

            pub fn toPeerID(self: @This()) !PeerID {
                var peer = PeerID{ .Ed25519 = .{ .pub_key_bytes = [_]u8{0} ** key_len } };
                var expected_len: usize = key_len;
                // var pub_key_out_slice = out[4..];
                if (c.EVP_PKEY_get_raw_public_key(self.key, &peer.Ed25519.pub_key_bytes, &expected_len) == 0) {
                    return error.GetPubKeyFailed;
                }

                return peer;
            }

            fn derEncoding(self: @This()) [DER_encoded_len]u8 {
                var out = [_]u8{0} ** DER_encoded_len;
                var out_ptr: ?[*]u8 = &out;
                const len = c.i2d_PUBKEY(self.key, &out_ptr);
                std.debug.assert(len == DER_encoded_len);
                return out;
            }

            fn libp2pExtension(self: @This()) [libp2p_extension_len]u8 {
                var out = [_]u8{0} ** libp2p_extension_len;
                std.mem.copy(u8, out[0..], libp2p_tls_handshake_prefix);

                var out_slice: []u8 = out[libp2p_tls_handshake_prefix.len..];
                var out_ptr: ?[*]u8 = out_slice.ptr;
                const len = c.i2d_PUBKEY(self.key, &out_ptr);
                std.debug.assert(len == DER_encoded_len);

                return out;
            }

            fn serializePb(self: @This(), out: []u8) !usize {
                assert(out.len >= pb_encoded_len);
                serializePbHeader(out);
                var actual_len: usize = key_len;
                var pub_key_out_slice = out[4..];
                if (c.EVP_PKEY_get_raw_public_key(self.key, pub_key_out_slice.ptr, &actual_len) == 0) {
                    return error.GetPubKeyFailed;
                }
                assert(actual_len == key_len);
                return pb_encoded_len;
            }

            fn serializePbHeader(out: []u8) void {
                assert(out.len >= (pb_encoded_len - key_len));
                out[0] = Key.pbFieldKey(1, 0);
                out[1] = @enumToInt(KeyType.Ed25519);

                out[2] = Key.pbFieldKey(2, 2);
                out[3] = key_len;
            }

            fn serializePbFromRaw(public_key: [32]u8, out: []u8) usize {
                assert(out.len >= pb_encoded_len);
                serializePbHeader(out);
                std.mem.copy(u8, out[4..], &public_key);
                return pb_encoded_len;
            }

            const PeerIDStrLen = blk: {
                const bytes = ([_]u8{
                    // cidv1
                    0x01,
                    // libp2p-key
                    0x72,
                    // multihash identity
                    0x00,
                    @intCast(u8, pb_encoded_len),
                } ++ [_]u8{0} ** pb_encoded_len);

                // +1 for the multibase prefix
                const b32_size = no_padding_encoding.encodeLen(bytes.len) + 1;
                break :blk b32_size;
            };

            pub fn fromPeerIDString(peer_id: []const u8) !OpenSSLKey.ED25519KeyPair.PublicKey {
                var buf = (([_]u8{
                    // cidv1
                    0x01,
                    // libp2p-key
                    0x72,
                    // multihash identity
                    0x00,
                    @intCast(u8, pb_encoded_len),
                }) ++ [_]u8{0} ** pb_encoded_len);

                if (peer_id[0] != 'b') {
                    return error.NotMultibase32;
                }

                // +1 for the multibase prefix
                var x = try no_padding_encoding.decode(buf[0..], peer_id[1..]);
                std.log.debug("x is {any}\n", .{x});
                std.log.debug("peer id is {s}\n", .{peer_id[1..]});
                std.log.debug("Key is {s}\n", .{std.fmt.fmtSliceHexLower(buf[0..])});
                {
                    var l2 = no_padding_encoding.decodeLen(peer_id[1..].len);
                    var buf2 = buf[0..l2];
                    var x2 = try no_padding_encoding.decode(buf2[0..], peer_id[1..]);
                    std.log.debug("x is {any}\n", .{x2});
                    std.log.debug("Key is {s}\n", .{std.fmt.fmtSliceHexLower(buf2[0..])});
                }

                var bufToDecode: []const u8 = undefined;
                if (buf[0] == 0x08) {
                    // raw pb
                    // bufToDecode = buf[0..];

                    // Hack, the above wasn't working with go-libp2p. Need to look into this
                    std.log.debug("Key is {s}\n", .{std.fmt.fmtSliceHexLower(buf[0..])});
                    return try OpenSSLKey.ED25519KeyPair.PublicKey.initFromRaw(buf[4..]);
                } else if (buf[0] != 0x01 or buf[1] != 0x72 or buf[2] != 0x00) {
                    std.log.debug("Header bytes are: {s}\n", .{std.fmt.fmtSliceHexLower(buf[0..4])});
                    return error.NotProperlyEncoded;
                } else {
                    // The key should be read starting at the 5th byte to remove the cid/multicodec/multihash
                    bufToDecode = buf[4..];
                }

                var key = try Key.deserializePb(bufToDecode);
                return try OpenSSLKey.ED25519KeyPair.PublicKey.initFromKey(key);
            }

            fn matchesKey(self: @This(), other_key: Key) !bool {
                if (other_key != .Ed25519) {
                    return error.WrongKeyType;
                }

                const other_key_bytes = other_key.Ed25519.key_bytes;
                if (other_key_bytes.len != key_len) {
                    return error.WrongLen;
                }

                var self_key = [_]u8{0} ** key_len;
                var expected_len: usize = key_len;
                if (c.EVP_PKEY_get_raw_public_key(self.key, &self_key, &expected_len) == 0) {
                    return error.GetPubKeyFailed;
                }

                var i: usize = 0;
                while (i < key_len) : (i += 1) {
                    if (other_key_bytes[i] != self_key[i]) {
                        return false;
                    }
                }

                return true;
            }

            pub fn initFromRaw(k: []const u8) !PublicKey {
                var key = c.EVP_PKEY_new_raw_public_key(c.EVP_PKEY_ED25519, null, k.ptr, k.len);
                if (key == null) {
                    return error.InitPubKeyFailed;
                }
                return PublicKey{ .key = key.? };
            }

            fn initFromKey(k: Key) !PublicKey {
                if (k != .Ed25519) {
                    return error.WrongKeyType;
                }

                return try initFromRaw(k.Ed25519.key_bytes[0..]);
            }

            fn deinit(self: @This()) void {
                c.EVP_PKEY_free(self.key);
            }
        };

        const Signature = struct {
            sig: [Len]u8,

            // https://ed25519.cr.yp.to sig fits in 64 bytes
            const Len = 64;

            fn fromSlice(s: []const u8) !Signature {
                if (s.len < Len) {
                    return error.WrongSignatureLen;
                }

                var self = Signature{ .sig = [_]u8{0} ** Len };
                std.mem.copy(u8, self.sig[0..], s[0..Len]);
                return self;
            }

            fn verify(self: Signature, pub_key: OpenSSLKey.ED25519KeyPair.PublicKey, msg: []u8) !bool {
                var md_ctx = c.EVP_MD_CTX_new();
                if (c.EVP_DigestVerifyInit(md_ctx, null, null, null, pub_key.key) == 0) {
                    return error.DigestVerifyInitFailed;
                }
                defer c.EVP_MD_CTX_free(md_ctx);

                //  EVP_DigestVerify(EVP_MD_CTX *ctx, const unsigned char *sigret,
                //           size_t siglen, const unsigned char *tbs, size_t tbslen);
                const err = c.EVP_DigestVerify(md_ctx, self.sig[0..], self.sig.len, msg.ptr, msg.len);

                // EVP_DigestVerify() return 1 for success; any other value
                // indicates failure. A return value of zero indicates that the
                // signature did not verify successfully (that is, tbs did not match
                // the original data or the signature had an invalid form), while
                // other values indicate a more serious error (and sometimes also
                // indicate an invalid signature form).
                switch (err) {
                    1 => {
                        return true;
                    },
                    0 => {
                        return false;
                    },
                    else => {
                        return error.DigestVerifyFailed;
                    },
                }
            }
        };

        pub fn new() !OpenSSLKey.ED25519KeyPair {
            var pkey: ?*c.EVP_PKEY = null;
            {
                var pctx: ?*c.EVP_PKEY_CTX = c.EVP_PKEY_CTX_new_id(c.EVP_PKEY_ED25519, null);
                _ = c.EVP_PKEY_keygen_init(pctx);
                _ = c.EVP_PKEY_keygen(pctx, &pkey);
                defer c.EVP_PKEY_CTX_free(pctx);
            }

            if (pkey == null) {
                return error.FailedToGenerate;
            }
            return OpenSSLKey.ED25519KeyPair{ .key = pkey.? };
        }

        pub fn fromPrivKey(b32PrivKey: []const u8) !OpenSSLKey.ED25519KeyPair {
            if (b32PrivKey[0] != 'b') {
                // TODO support all of multibase
                return error.notBase32Multibase;
            }

            var k: [key_len]u8 = undefined;
            _ = try no_padding_encoding.decode(&k, b32PrivKey[1..]);
            var key = c.EVP_PKEY_new_raw_private_key(c.EVP_PKEY_ED25519, null, &k, k.len);

            return OpenSSLKey.ED25519KeyPair{ .key = key.? };
        }

        pub const priv_b32_size = no_padding_encoding.encodeLen(key_len) + 1;
        pub fn privKey(self: *@This()) ![priv_b32_size]u8 {
            var priv_key_bytes = [_]u8{0} ** key_len;
            var expected_len: usize = key_len;
            // var pub_key_out_slice = out[4..];
            if (c.EVP_PKEY_get_raw_private_key(self.key, &priv_key_bytes, &expected_len) == 0) {
                return error.GetPrivKeyFailed;
            }

            var buf = [_]u8{0} ** priv_b32_size;
            // Multibase "b" base32
            buf[0] = 'b';

            _ = no_padding_encoding.encode(buf[1..], priv_key_bytes[0..]);
            return buf;
        }

        pub fn deinit(self: ED25519KeyPair) void {
            c.EVP_PKEY_free(self.key);
        }

        pub fn toPubKey(self: *ED25519KeyPair) PublicKey {
            return PublicKey{ .key = self.key };
        }

        fn genPkcs12() !PKCS12 {
            return error.ImplementMe;
        }

        fn sign(self: ED25519KeyPair, msg: []const u8) !Signature {
            var sig = Signature{ .sig = [_]u8{0} ** Signature.Len };
            var sig_len: usize = Signature.Len;
            // EVP_MD_CTX *md_ctx = EVP_MD_CTX_new();
            var md_ctx = c.EVP_MD_CTX_new();
            if (c.EVP_DigestSignInit(md_ctx, null, null, null, self.key) == 0) {
                return error.DigestSignInitFailed;
            }
            defer c.EVP_MD_CTX_free(md_ctx);

            // Calculate the requires size for the signature by passing a NULL buffer
            // EVP_DigestSign(md_ctx, NULL, &sig_len, msg, msg_len);
            var sig_slice: []u8 = sig.sig[0..];
            if (c.EVP_DigestSign(md_ctx, sig_slice.ptr, &sig_len, msg.ptr, msg.len) == 0) {
                return error.DigestSignFailed;
            }

            return sig;
        }

        fn signToDest(self: ED25519KeyPair, msg: []u8, dest: []u8) !void {
            assert(dest.len >= Signature.Len);

            var sig_len: usize = Signature.Len;
            // EVP_MD_CTX *md_ctx = EVP_MD_CTX_new();
            var md_ctx = c.EVP_MD_CTX_new();
            if (c.EVP_DigestSignInit(md_ctx, null, null, null, self.key) == 0) {
                return error.DigestSignInitFailed;
            }
            defer c.EVP_MD_CTX_free(md_ctx);

            // Calculate the requires size for the signature by passing a NULL buffer
            // EVP_DigestSign(md_ctx, NULL, &sig_len, msg, msg_len);
            if (c.EVP_DigestSign(md_ctx, dest.ptr, &sig_len, msg.ptr, msg.len) == 0) {
                return error.DigestSignFailed;
            }
        }
    };

    fn libp2pExtension(self: @This(), allocator: Allocator) ![]u8 {
        const DER_encoded_len: usize = switch (self) {
            .ECDSA => 91,
            .Ed25519 => ED25519KeyPair.key_len + 12,
            else => {
                @panic("TODO implement");
            },
        };

        const k: *c.EVP_PKEY = switch (self) {
            .ECDSA => self.ECDSA.key,
            .Ed25519 => self.Ed25519.key,
            else => {
                @panic("TODO implement");
            },
        };

        const libp2p_extension_len = DER_encoded_len + libp2p_tls_handshake_prefix.len;

        var out = try allocator.alloc(u8, libp2p_extension_len);
        std.mem.copy(u8, out[0..], libp2p_tls_handshake_prefix);

        var out_slice: []u8 = out[libp2p_tls_handshake_prefix.len..];
        var out_ptr: ?[*]u8 = out_slice.ptr;
        const len = c.i2d_PUBKEY(k, &out_ptr);
        std.debug.assert(len == DER_encoded_len);

        return out;
    }
};

pub const Key = union(KeyType) {
    RSA: struct {},
    Ed25519: Ed25519,
    Secp256k1: struct {},
    ECDSA: struct {
        key_bytes: [OpenSSLKey.ECDSAKeyPair.key_len]u8,
    },

    pub const Ed25519 = struct {
        pub const key_len = 32;
        key_bytes: [key_len]u8,
    };

    pub fn deinit(self: Key, allocator: Allocator) void {
        _ = self;
        _ = allocator;
        // allocator.free(self.key_bytes);
    }

    pub fn toPeerID(self: *const Key) PeerID {
        switch (self.*) {
            .Ed25519 => {
                return .{ .Ed25519 = .{ .pub_key_bytes = self.Ed25519.key_bytes } };
            },
            .ECDSA => {
                return .{ .ECDSA = .{ .pub_key_bytes = self.ECDSA.key_bytes } };
            },
            else => {
                @panic("other key types not implemented");
            },
        }
    }

    pub fn toPeerIDString(self: Key, allocator: Allocator) ![]u8 {
        switch (self) {
            .Ed25519 => {
                var pub_key = try OpenSSLKey.ED25519KeyPair.PublicKey.initFromKey(self);
                defer pub_key.deinit();

                const peer_id = try (try pub_key.toPeerID()).toString(allocator);
                return peer_id;
            },
            .ECDSA => {
                // Directly convert key bytes to PeerID and get string representation
                const peer_id = PeerID{ .ECDSA = .{ .pub_key_bytes = self.ECDSA.key_bytes } };
                return try peer_id.toString(allocator);
            },
            else => {
                return error.UnsupportedKeyType;
            },
        }
    }

    fn matchesPeerIDStr(self: Key, peer_id_str: []u8) !bool {
        switch (self) {
            .Ed25519 => {
                var pub_key = try OpenSSLKey.ED25519KeyPair.PublicKey.initFromKey(self);
                defer pub_key.deinit();
                return pub_key.matchesPeerIDStr(peer_id_str);
            },
            else => {
                return error.UnsupportedKeyType;
            },
        }
    }

    fn matchesKey(self: Key, other_key: Key) !bool {
        switch (self.key_type) {
            .Ed25519 => {
                var pub_key = try OpenSSLKey.ED25519KeyPair.PublicKey.initFromKey(self);
                defer pub_key.deinit();
                return pub_key.matchesKey(other_key);
            },
            else => {
                return error.UnsupportedKeyType;
            },
        }
    }

    pub inline fn pbFieldKey(num: u8, tag: u3) u8 {
        return num << 3 | tag;
    }

    fn serializePb(self: Key, out: *std.ArrayList(u8)) !void {
        // Key type
        try protobuf.append_varint(out, pbFieldKey(1, 0), .Simple);
        try protobuf.append_varint(out, @enumToInt(self), .Simple);

        // Key Bytes
        try protobuf.append_varint(out, pbFieldKey(2, 2), .Simple);
        switch (self) {
            .Ed25519 => {
                try protobuf.append_varint(out, self.Ed25519.key_bytes.len, .Simple);
                try out.appendSlice(self.Ed25519.key_bytes[0..]);
            },
            .ECDSA => {
                try protobuf.append_varint(out, self.ECDSA.key_bytes.len, .Simple);
                try out.appendSlice(self.ECDSA.key_bytes[0..]);
            },
            else => {
                return error.UnsupportedKeyType;
            },
        }
    }

    const PbField = union(enum) { u8: u8, bytes: []const u8 };

    fn deserializePb(buffer: []const u8) !Key {
        // https://developers.google.com/protocol-buffers/docs/encoding
        var key_type: ?KeyType = undefined;
        var key_bytes: ?[]const u8 = undefined;
        var i: usize = 0;
        while (i < buffer.len) {
            var field = protobuf.decode_varint(u8, buffer[i..]);
            i += field.size;

            const field_tag = field.value & 0b111;
            const field_num = field.value >> 3;

            var field_val: PbField = switch (field_tag) {
                0 => blk: {
                    const varint_field = protobuf.decode_varint(u8, buffer[i..]);
                    i += varint_field.size;
                    break :blk PbField{ .u8 = varint_field.value };
                },
                2 => blk: {
                    const field_len = protobuf.decode_varint(usize, buffer[i..]);
                    i += field_len.size;
                    defer i += field_len.value;
                    break :blk PbField{ .bytes = buffer[i .. i + field_len.value] };
                },
                else => {
                    std.log.debug("Unknown field tag {}\n", .{field_tag});
                    return error.UnsupportedFieldTag;
                },
            };

            if (field_num == 1 and field_val == .u8) {
                key_type = @intToEnum(KeyType, field_val.u8);
            } else if (field_num == 2 and field_val == .bytes) {
                key_bytes = field_val.bytes;
            } else {
                std.log.debug("Field num is {} and field_val is {any}", .{ field_num, field_val });
                return error.UnknownPB;
            }
        }

        if (key_type == null or key_bytes == null) {
            return error.PBMissingFields;
        }

        switch (key_type.?) {
            KeyType.Ed25519 => {
                if (key_bytes.?.len < OpenSSLKey.ED25519KeyPair.key_len) {
                    return error.InvalidKeyLength;
                }

                var k: Key = Key{ .Ed25519 = .{ .key_bytes = [_]u8{0} ** OpenSSLKey.ED25519KeyPair.key_len } };
                std.mem.copy(u8, k.Ed25519.key_bytes[0..], key_bytes.?[0..OpenSSLKey.ED25519KeyPair.key_len]);
                return k;
            },
            KeyType.ECDSA => {
                if (key_bytes.?.len < OpenSSLKey.ECDSAKeyPair.key_len) {
                    return error.InvalidKeyLength;
                }

                var k: Key = Key{ .ECDSA = .{ .key_bytes = [_]u8{0} ** OpenSSLKey.ECDSAKeyPair.key_len } };
                std.mem.copy(u8, k.ECDSA.key_bytes[0..], key_bytes.?[0..OpenSSLKey.ECDSAKeyPair.key_len]);
                return k;
            },
            else => {
                return error.UnsupportedKeyType;
            },
        }
    }
};

pub const Libp2pTLSCert = struct {
    host_key: OpenSSLKey.ED25519KeyPair,
    cert_key: OpenSSLKey.ED25519KeyPair,

    // https://letsencrypt.org/docs/a-warm-welcome-to-asn1-and-der/#sequence-encoding
    // https://www.itu.int/ITU-T/studygroups/com17/languages/X.690-0207.pdf
    const sequence_tag = 0x30;
    const octet_tag = 0x04;
    // How many bytes a tag uses
    const tag_size = 1;
    // How many bytes a length uses. (Only in definite form < 127)
    const length_size = 1;
    //                          seq_tag    seq_len       octet tag  octet_len     host_pubkey                                          octet tag  octet_len     signature
    const extension_byte_size = tag_size + length_size + tag_size + length_size + OpenSSLKey.ED25519KeyPair.PublicKey.pb_encoded_len + tag_size + length_size + OpenSSLKey.ED25519KeyPair.Signature.Len;

    pub fn insertExtension(x509: X509, serialized_libp2p_extension: [extension_byte_size]u8) !void {
        std.log.debug("\n\n serialized libp2p extension {s}\n\n", .{std.fmt.fmtSliceHexLower(serialized_libp2p_extension[0..])});
        try x509.insertLibp2pExtension(serialized_libp2p_extension[0..]);
    }

    pub fn serializeLibp2pExt(self: @This()) ![extension_byte_size]u8 {
        var out = [_]u8{0} ** extension_byte_size;

        // Have the compiler check our math
        comptime var actual_bytes_written = 0;

        out[0] = sequence_tag;
        actual_bytes_written += 1;
        out[1] = extension_byte_size - tag_size - length_size;
        actual_bytes_written += 1;
        out[2] = octet_tag;
        actual_bytes_written += 1;
        out[3] = OpenSSLKey.ED25519KeyPair.PublicKey.pb_encoded_len;
        actual_bytes_written += 1;

        // Write pubkey
        const bytes_written = try OpenSSLKey.ED25519KeyPair.PublicKey.serializePb(.{ .key = self.host_key.key }, out[4..]);
        actual_bytes_written += OpenSSLKey.ED25519KeyPair.PublicKey.pb_encoded_len;

        out[4 + bytes_written] = octet_tag;
        actual_bytes_written += 1;
        out[5 + bytes_written] = OpenSSLKey.ED25519KeyPair.Signature.Len;
        actual_bytes_written += 1;

        var libp2p_extension_data = OpenSSLKey.ED25519KeyPair.PublicKey.libp2pExtension(.{ .key = self.cert_key.key });

        try self.host_key.signToDest(
            libp2p_extension_data[0..],
            out[6 + bytes_written ..],
        );
        actual_bytes_written += OpenSSLKey.ED25519KeyPair.Signature.Len;

        if (actual_bytes_written != extension_byte_size) {
            @compileError("actual_bytes_written != expected_bytes_to_write");
        }

        return out;
    }

    const DeserializedParts = struct {
        allocator: Allocator,
        host_pubkey_bytes: []const u8,
        extension_data: []const u8,

        fn deinit(self: DeserializedParts) void {
            self.allocator.free(self.host_pubkey_bytes);
            self.allocator.free(self.extension_data);
        }
    };

    // Return slices to serialized public key and
    pub fn deserializeLibp2pExt(allocator: Allocator, buffer: []const u8) !DeserializedParts {
        var buf_ptr: ?[*]const u8 = buffer.ptr;
        var seq = c.d2i_ASN1_SEQUENCE_ANY(null, &buf_ptr, @intCast(c_long, buffer.len));
        if (seq == null) {
            return error.ParseError;
        }
        defer {
            _ = c.OPENSSL_sk_pop_free(c.ossl_check_ASN1_TYPE_sk_type(seq), c.ossl_check_ASN1_TYPE_freefunc_type(c.ASN1_TYPE_free));
        }

        var maybe_octet_str = c.sk_ASN1_TYPE_shift(seq);
        defer c.ASN1_TYPE_free(maybe_octet_str);

        var octet_str = maybe_octet_str.*.value.octet_string;
        var octet_str_ptr = c.ASN1_STRING_get0_data(octet_str);
        var octet_str_len = @intCast(usize, c.ASN1_STRING_length(octet_str));
        var octet_str_slice = octet_str_ptr[0..octet_str_len];

        var host_pubkey_bytes = try allocator.alloc(u8, octet_str_len);
        std.mem.copy(u8, host_pubkey_bytes, octet_str_slice);

        var maybe_octet_str_2 = c.sk_ASN1_TYPE_shift(seq);
        defer c.ASN1_TYPE_free(maybe_octet_str_2);

        octet_str = maybe_octet_str_2.*.value.octet_string;
        octet_str_ptr = c.ASN1_STRING_get0_data(octet_str);
        octet_str_len = @intCast(usize, c.ASN1_STRING_length(octet_str));
        octet_str_slice = octet_str_ptr[0..octet_str_len];

        var extension_data = try allocator.alloc(u8, octet_str_len);
        std.mem.copy(u8, extension_data, octet_str_slice);

        return DeserializedParts{
            .allocator = allocator,
            .host_pubkey_bytes = host_pubkey_bytes,
            .extension_data = extension_data,
        };
    }

    pub fn verify(x509: X509, allocator: Allocator) !Key {
        const libp2p_extension = try x509.getExtensionData(libp2p_extension_oid);

        const libp2p_decoded = try deserializeLibp2pExt(allocator, libp2p_extension);
        defer libp2p_decoded.deinit();

        const cert_key = try x509.getPubKey();
        // defer cert_key.deinit();

        var k = try Key.deserializePb(libp2p_decoded.host_pubkey_bytes);

        // std.log.debug("\n key is {s}\n", .{std.fmt.fmtSliceHexLower(k.key_bytes)});
        var host_pub_key = try OpenSSLKey.ED25519KeyPair.PublicKey.initFromKey(k);
        defer host_pub_key.deinit();

        var libp2p_extension_data_again = try cert_key.libp2pExtension(allocator);
        defer allocator.free(libp2p_extension_data_again);
        var sig = try OpenSSLKey.ED25519KeyPair.Signature.fromSlice(libp2p_decoded.extension_data);
        const valid = try sig.verify(host_pub_key, libp2p_extension_data_again[0..]);
        if (!valid) {
            return error.SignatureVerificationFailed;
        }

        return k;
    }
};

test "Generate Key, and more" {
    const kp = try OpenSSLKey.ED25519KeyPair.new();
    defer kp.deinit();

    const x509 = try X509.init(kp, null);
    defer x509.deinit();

    const pkcs12 = try PKCS12.init(kp, x509);
    defer pkcs12.deinit();

    var buf = [_]u8{0} ** 1024;
    const bytes_read = try pkcs12.read(buf[0..]);
    std.log.debug("Read {} bytes.\n", .{bytes_read});
    try std.testing.expect(bytes_read > 0);
}

test "Deserialize Public Key proto" {
    // TODO actually support protobufs
    const allocator = std.testing.allocator;

    var example_pub_key_bytes = [_]u8{ 8, 1, 18, 32, 63, 233, 39, 184, 35, 221, 125, 215, 150, 255, 5, 46, 49, 208, 166, 231, 54, 202, 240, 87, 100, 229, 236, 194, 171, 133, 136, 243, 7, 192, 97, 121 };
    const example_pub_key = try Key.deserializePb(example_pub_key_bytes[0..]);
    // defer example_pub_key.deinit(allocator);

    var round_trip = std.ArrayList(u8).init(allocator);
    defer round_trip.deinit();

    try example_pub_key.serializePb(&round_trip);

    try std.testing.expectEqualSlices(u8, example_pub_key_bytes[0..], round_trip.items[0..]);
}

test "Sign and Verify" {
    var msg = "hello world".*;

    var kp = try OpenSSLKey.ED25519KeyPair.new();
    defer kp.deinit();

    var sig = try kp.sign(msg[0..]);
    std.log.debug("\n Sig is {s}\n", .{std.fmt.fmtSliceHexLower(sig.sig[0..])});

    try std.testing.expect(try sig.verify(OpenSSLKey.ED25519KeyPair.PublicKey{ .key = kp.key }, msg[0..]));

    // Flip the byte, sig should fail
    sig.sig[0] ^= 0xff;
    try std.testing.expect(!(try sig.verify(OpenSSLKey.ED25519KeyPair.PublicKey{ .key = kp.key }, msg[0..])));
}

test "libp2p extension" {
    var kp = try OpenSSLKey.ED25519KeyPair.new();
    defer kp.deinit();

    const pk = OpenSSLKey.ED25519KeyPair.PublicKey{ .key = kp.key };
    const encoded = pk.derEncoding();
    std.log.debug("\n Encoded is {encoded}\n", .{std.fmt.fmtSliceHexLower(encoded[0..])});

    const libp2p_encoded = pk.libp2pExtension();
    std.log.debug("\n Encoded is {s}\n", .{std.fmt.fmtSliceHexLower(libp2p_encoded[0..])});
}

test "make cert" {
    var host_key = try OpenSSLKey.ED25519KeyPair.new();
    defer host_key.deinit();

    var cert_key = try OpenSSLKey.ED25519KeyPair.new();
    defer cert_key.deinit();

    const libp2p_extension = try Libp2pTLSCert.serializeLibp2pExt(.{ .host_key = host_key, .cert_key = cert_key });

    var x509 = try X509.init(cert_key, libp2p_extension[0..]);
    defer x509.deinit();

    // try Libp2pTLSCert.insertExtension(x509, libp2p_extension);

    // Verification part

    const allocator = std.testing.allocator;
    const k = try Libp2pTLSCert.verify(x509, allocator);
    // defer k.deinit(allocator);

    var expected_peer_id = try (try host_key.toPubKey().toPeerID()).toString(allocator);
    defer allocator.free(expected_peer_id);
    // var expected_peer_id_slice: []u8 = expected_peer_id[0..];
    var actual_peer_id = try k.toPeerIDString(allocator);
    defer allocator.free(actual_peer_id);

    // Various ways to check that the key is correct
    try std.testing.expectEqualStrings(expected_peer_id, actual_peer_id);
}

test "To PeerID string" {
    const kp = try OpenSSLKey.ED25519KeyPair.new();
    defer kp.deinit();

    const pub_key = OpenSSLKey.ED25519KeyPair.PublicKey{ .key = kp.key };
    const peer_id = try pub_key.toPeerID();
    const allocator = std.testing.allocator;
    const peer_id_str = try peer_id.toString(allocator);
    defer allocator.free(peer_id_str);
    std.log.debug("Peer id {s}\n", .{peer_id_str});
}

test "Round trip peer id" {
    var kp = try OpenSSLKey.ED25519KeyPair.new();
    defer kp.deinit();

    const p = try kp.toPubKey().toPeerID();
    const p_str = p.Ed25519.toString();
    var kp2 = try OpenSSLKey.ED25519KeyPair.PublicKey.fromPeerIDString(&p_str);
    const p2 = try kp2.toPeerID();

    try std.testing.expect(p.equal(p2));
}

test "ECDSA key generation" {
    var kp = try OpenSSLKey.ECDSAKeyPair.new();
    defer kp.deinit();

    // Verify the key is valid
    var ec_key = c.EVP_PKEY_get1_EC_KEY(kp.key);
    try std.testing.expect(ec_key != null);
    defer c.EC_KEY_free(ec_key);

    var ec_point = c.EC_KEY_get0_public_key(ec_key);
    try std.testing.expect(ec_point != null);

    var ec_group = c.EC_KEY_get0_group(ec_key);
    try std.testing.expect(ec_group != null);
}

test "ECDSA Sign and Verify" {
    var msg = "hello world".*;

    var kp = try OpenSSLKey.ECDSAKeyPair.new();
    defer kp.deinit();

    var sig = try kp.sign(msg[0..]);
    std.log.debug("\n ECDSA Sig is {s}\n", .{std.fmt.fmtSliceHexLower(sig.sig[0..])});

    // Verify using the same key's public part
    try std.testing.expect(try sig.verify(OpenSSLKey.ECDSAKeyPair.PublicKey{ .key = kp.key }, msg[0..]));

    // Modify the signature, verification should fail
    sig.sig[0] ^= 0xff;
    try std.testing.expect(!(try sig.verify(OpenSSLKey.ECDSAKeyPair.PublicKey{ .key = kp.key }, msg[0..])));
}

test "ECDSA PeerID generation" {
    var kp = try OpenSSLKey.ECDSAKeyPair.new();
    defer kp.deinit();

    // Get PeerID from public key
    const pub_key = OpenSSLKey.ECDSAKeyPair.PublicKey{ .key = kp.key };
    const peer_id = try pub_key.toPeerID();

    // Convert to string
    const allocator = std.testing.allocator;
    const peer_id_str = try peer_id.toString(allocator);
    defer allocator.free(peer_id_str);

    std.log.debug("ECDSA Peer id {s}\n", .{peer_id_str});

    // Verify the peer ID starts with the expected multibase prefix
    try std.testing.expectEqual(@as(u8, 'b'), peer_id_str[0]);
}

test "ECDSA protobuf serialization" {
    const allocator = std.testing.allocator;

    // Create a new ECDSA key
    var kp = try OpenSSLKey.ECDSAKeyPair.new();
    defer kp.deinit();

    // Get peer ID
    const pub_key = OpenSSLKey.ECDSAKeyPair.PublicKey{ .key = kp.key };
    const peer_id = try pub_key.toPeerID();

    // Create a Key from the peer_id
    var key = Key{ .ECDSA = .{ .key_bytes = peer_id.ECDSA.pub_key_bytes } };

    // Serialize to protobuf
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try key.serializePb(&buf);

    // Deserialize from protobuf
    var deserialized_key = try Key.deserializePb(buf.items);

    // Compare original and deserialized keys
    switch (deserialized_key) {
        .ECDSA => {
            try std.testing.expectEqualSlices(u8, key.ECDSA.key_bytes[0..], deserialized_key.ECDSA.key_bytes[0..]);
        },
        else => {
            try std.testing.expect(false); // Should be ECDSA
        },
    }
}

test "base32 encoding" {
    std.testing.log_level = .debug;
    const s = "080112208a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f01";
    const encoding = no_padding_encoding;
    var buf = [_]u8{0} ** (s.len / 2);
    const encoded_len = comptime encoding.encodeLen(buf.len);
    const decoded_len = comptime encoding.decodeLen(encoded_len);
    var roundtrip_buf = [_]u8{0} ** decoded_len;
    _ = try std.fmt.hexToBytes(&buf, s);
    var buf_encoded = [_]u8{0} ** encoded_len;
    _ = encoding.encode(&buf_encoded, buf[0..]);

    _ = try encoding.decode(roundtrip_buf[0..], buf_encoded[0..]);

    try std.testing.expectEqualSlices(u8, buf[0..], roundtrip_buf[0..buf.len]);
}
test "ECDSA private key produces expected public key" {
    const private_key_proto_hex: *const [250:0]u8 = "08031279307702010104203E5B1FE9712E6C314942A750BD67485DE3C1EFE85B1BFB520AE8F9AE3DFA4A4CA00A06082A8648CE3D030107A14403420004DE3D300FA36AE0E8F5D530899D83ABAB44ABF3161F162A4BC901D8E6ECDA020E8B6D5F8DA30525E71D6851510C098E5C47C646A597FB4DCEC034E9F77C409E62";

    const proto_len = private_key_proto_hex.len / 2;
    var proto_buf = try std.testing.allocator.alloc(u8, proto_len);
    defer std.testing.allocator.free(proto_buf);
    _ = try std.fmt.hexToBytes(proto_buf, private_key_proto_hex);

    const der_priv = proto_buf[4..];

    var kp = try OpenSSLKey.ECDSAKeyPair.fromDerPrivateKey(der_priv);
    defer kp.deinit();
    const pub_key = kp.toPubKey();
    const peer_id = try pub_key.toPeerID();

    const expected_full_hex: *const [190:0]u8 = "0803125b3059301306072a8648ce3d020106082a8648ce3d03010703420004de3d300fa36ae0e8f5d530899d83abab44abf3161f162a4bc901d8e6ecda020e8b6d5f8da30525e71d6851510c098e5c47c646a597fb4dcec034e9f77c409e62";

    const expected_full_len = expected_full_hex.len / 2;
    var expected_full_buf = try std.testing.allocator.alloc(u8, expected_full_len);
    defer std.testing.allocator.free(expected_full_buf);
    _ = try std.fmt.hexToBytes(expected_full_buf, expected_full_hex);

    var key_start_idx: usize = 0;
    var i: usize = 0;
    while (i < expected_full_buf.len - 2) : (i += 1) {
        if (i > 0 and expected_full_buf[i - 1] == 0x42 and expected_full_buf[i] == 0x00 and expected_full_buf[i + 1] == 0x04) {
            key_start_idx = i + 2;
            break;
        }
    }

    if (key_start_idx == 0 or key_start_idx + 64 > expected_full_buf.len) {
        return error.InvalidExpectedKey;
    }

    const expected_raw_key = expected_full_buf[key_start_idx .. key_start_idx + 64];

    try std.testing.expectEqualSlices(
        u8,
        expected_raw_key,
        peer_id.ECDSA.pub_key_bytes[0..64],
    );
}
