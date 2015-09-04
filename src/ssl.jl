type SSLConfig
    data::Ptr{Void}
    rng
    chain::CRT
    dbg

    function SSLConfig()
        conf = new()
        conf.data = Libc.malloc(1000)  # 360
        ccall((:mbedtls_ssl_config_init, MBED_TLS), Void, (Ptr{Void},), conf.data)
        finalizer(conf, conf->begin
            ccall((:mbedtls_ssl_config_free, MBED_TLS), Void, (Ptr{Void},), conf.data)
            Libc.free(conf.data)
        end
        )
        conf
    end
end

type SSLContext <: IO
    data::Ptr{Void}
    config::SSLConfig
    bio

    function SSLContext()
        ctx = new()
        ctx.data = Libc.malloc(1000)  # 488
        ccall((:mbedtls_ssl_init, MBED_TLS), Void, (Ptr{Void},), ctx.data)
        finalizer(ctx, ctx->begin
            ccall((:mbedtls_ssl_free, MBED_TLS), Void, (Ptr{Void},), ctx.data)
            Libc.free(ctx.data)
        end
        )
        ctx
    end
end

function config_defaults!(config::SSLConfig, endpoint=MBEDTLS_SSL_IS_CLIENT,
    transport=MBEDTLS_SSL_TRANSPORT_STREAM, preset=MBEDTLS_SSL_PRESET_DEFAULT)
    @err_check ccall((:mbedtls_ssl_config_defaults, MBED_TLS), Cint,
        (Ptr{Void}, Cint, Cint, Cint),
        config.data, endpoint, transport, preset)
end

function authmode!(config::SSLConfig, auth)
    ccall((:mbedtls_ssl_conf_authmode, MBED_TLS), Void,
        (Ptr{Void}, Cint),
        config.data, auth)
end

function rng!(config::SSLConfig, f_rng::Ptr{Void}, ctx)
    ccall((:mbedtls_ssl_conf_rng, MBED_TLS), Void,
        (Ptr{Void}, Ptr{Void}, Ptr{Void}),
        config.data, f_rng, ctx)
end

function rng!(config::SSLConfig, rng::AbstractRNG)
    config.rng = rng
    rng!(config, c_rng, pointer_from_objref(rng))
end

function ca_chain!(config::SSLConfig, chain=crt_parse_file(TRUSTED_CERT_FILE))
    config.chain = chain
    ccall((:mbedtls_ssl_conf_ca_chain, MBED_TLS), Void,
        (Ptr{Void}, Ptr{Void}, Ptr{Void}),
        config.data, chain.data, C_NULL)
end

function setup!(ctx::SSLContext, conf::SSLConfig)
    ctx.config = conf
    @err_check ccall((:mbedtls_ssl_setup, MBED_TLS), Cint,
        (Ptr{Void}, Ptr{Void}),
        ctx.data, conf.data)
end

function set_bio!(ssl_ctx::SSLContext, ctx, f_send::Ptr{Void}, f_recv::Ptr{Void})
    ccall((:mbedtls_ssl_set_bio, MBED_TLS), Void,
        (Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{Void}, Ptr{Void}),
        ssl_ctx.data, ctx, f_send, f_recv, C_NULL)
end

function f_send(c_ctx, c_msg, sz)
    jl_ctx = unsafe_pointer_to_objref(c_ctx)
    jl_msg = pointer_to_array(c_msg, sz, false)
    Cint(write(jl_ctx, jl_msg))
end

function f_recv(c_ctx, c_msg, sz)
    jl_ctx = unsafe_pointer_to_objref(c_ctx)
    jl_msg = pointer_to_array(c_msg, sz, false)
    n = readbytes!(jl_ctx, jl_msg, sz)
    Cint(n)
end

function set_bio!{T<:IO}(ssl_ctx::SSLContext, jl_ctx::T)
    ssl_ctx.bio = jl_ctx
    set_bio!(ssl_ctx, pointer_from_objref(jl_ctx), c_send, c_recv)
end

function dbg!(conf::SSLConfig, f::Ptr{Void}, p)
    ccall((:mbedtls_ssl_conf_dbg, MBED_TLS), Void,
        (Ptr{Void}, Ptr{Void}, Ptr{Void}),
        conf.data, f, p)
end

function f_dbg(c_ctx, level, filename, number, msg)
    jl_ctx = unsafe_pointer_to_objref(c_ctx)
    jl_ctx(level, bytestring(filename), number, bytestring(msg))
    nothing
end

function dbg!(conf::SSLConfig, f)
    conf.dbg = f
    dbg!(conf, c_dbg, pointer_from_objref(f))
end

function handshake(ctx::SSLContext)
    @err_check ccall((:mbedtls_ssl_handshake, MBED_TLS), Cint,
        (Ptr{Void},), ctx.data)
end

function Base.write(ctx::SSLContext, msg::Vector{UInt8})
    n = ccall((:mbedtls_ssl_write, MBED_TLS), Cint,
        (Ptr{Void}, Ptr{Void}, Csize_t),
        ctx.data, msg, sizeof(msg))
    Int(n)
end

function Base.readbytes!(ctx::SSLContext, buf::Vector{UInt8}, nbytes=length(buf))
    n = ccall((:mbedtls_ssl_read, MBED_TLS), Cint,
        (Ptr{Void}, Ptr{Void}, Csize_t),
        ctx.data, buf, nbytes)
    n<0 && mbed_err(n)
    n < length(buf) && resize!(buf, n)
    Int(n)
end

function get_peer_cert(ctx::SSLContext)
    data = ccall((:mbedtls_ssl_get_peer_cert, MBED_TLS), Ptr{Void}, (Ptr{Void},), ctx.data)
    CRT(data)
end

function get_version(ctx::SSLContext)
    data = ccall((:mbedtls_ssl_get_version, MBED_TLS), Ptr{UInt8}, (Ptr{Void},), ctx.data)
    bytestring(data)
end

function get_ciphersuite(ctx::SSLContext)
    data = ccall((:mbedtls_ssl_get_ciphersuite, MBED_TLS), Ptr{UInt8}, (Ptr{Void},), ctx.data)
    bytestring(data)
end

function Base.nb_available(ctx::SSLContext)
    n = ccall((:mbedtls_ssl_get_bytes_avail, MBED_TLS), Csize_t, (Ptr{Void},), ctx.data)
    Int(n)
end

function __sslinit__()
    global const c_send = cfunction(f_send, Cint, (Ptr{Void}, Ptr{UInt8}, Csize_t))
    global const c_recv = cfunction(f_recv, Cint, (Ptr{Void}, Ptr{UInt8}, Csize_t))
    global const c_dbg = cfunction(f_dbg, Void,
        (Ptr{Void}, Cint, Ptr{UInt8}, Cint, Ptr{UInt8}))
    global const TRUSTED_CERT_FILE = joinpath(dirname(@__FILE__), "../deps/cacert.pem")
end
