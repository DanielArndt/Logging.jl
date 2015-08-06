module Logging

using Compat.Libc: strftime

import Base: show

export debug, info, warn, err, critical, log,
       @debug, @info, @warn, @err, @error, @critical, @log,
       Logger,
       LogLevel, DEBUG, INFO, WARNING, ERROR, CRITICAL, OFF,
       LogFacility,
       SysLog

if VERSION < v"0.4.0-dev+3587"
    include("enum.jl")
end

@enum LogLevel OFF=-1 CRITICAL=2 ERROR WARNING INFO=6 DEBUG

try
    DEBUG < CRITICAL
catch
    Base.isless(x::LogLevel, y::LogLevel) = isless(x.val, y.val)
end

function Base.convert(::Type{LogLevel}, x::String)
    for lvl in LogLevel
        if lvl[1] == symbol(x)
            return LogLevel(lvl[2])
        end
    end
    error(InexactError())
end

@enum LogFacility LOG_KERN LOG_USER LOG_MAIL LOG_DAEMON LOG_AUTH LOG_SYSLOG LOG_LPR LOG_NEWS LOG_UUCP LOG_CRON LOG_AUTHPRIV LOG_LOCAL0=16 LOG_LOCAL1 LOG_LOCAL2 LOG_LOCAL3 LOG_LOCAL4 LOG_LOCAL5 LOG_LOCAL6 LOG_LOCAL7

try
    LOG_KERN < LOG_USER
catch
    Base.isless(x::LogFacility, y::LogFacility) = isless(x.val, y.val)
end

type SysLog
    socket::UdpSocket
    ip::IPv4
    port::Uint16
    facility::LogFacility
    machine::String
    user::String

    SysLog(host::String, port::Int) = new(UdpSocket(), getaddrinfo(host), uint16(port), LOG_USER, gethostname(), Base.source_path()==nothing ? "" : basename(Base.source_path()))
    SysLog(host::String, port::Int, facility::LogFacility, machine::String, user::String) = new(UdpSocket(), getaddrinfo(host), uint16(port), facility, machine, user)

end

function log(syslog::SysLog, level::LogLevel, logger_name::String, msg...)
    t = time()
    # syslog needs a timestamp in the form: YYYY-MM-DDTHH:MM:SS-TZ:TZ
    timestamp = string(strftime("%Y-%m-%dT%H:%M:%S",t), strftime("%z",t)[1:end-2], ":", strftime("%z",t)[end-1:end])
    log_msg = string("<", (uint16(syslog.facility) << 3) + uint16(level), ">1 ", timestamp, " ", syslog.machine, " ", syslog.user, " - - - ", level, ":", logger_name,":", msg...)
    send(syslog.socket, syslog.ip, syslog.port, log_msg)
end

LogOutput = Union(IO,SysLog)

type Logger
    name::String
    level::LogLevel
    output::Array{LogOutput,1}
    parent::Logger

    Logger(name::String, level::LogLevel, output::IO, parent::Logger) = new(name, level, [output], parent)
    Logger(name::String, level::LogLevel, output::IO) = (x = new(); x.name = name; x.level=level; x.output=[output]; x.parent=x)
    Logger(name::String, level::LogLevel, output::Array{LogOutput,1}, parent::Logger) = new(name, level, output, parent)
    Logger(name::String, level::LogLevel, output::Array{LogOutput,1}) = (x = new(); x.name = name; x.level=level; x.output=output; x.parent=x)

end

show(io::IO, logger::Logger) = print(io, "Logger(", join([logger.name,
                                                          logger.level,
                                                          logger.output,
                                                          logger.parent.name], ","), ")")

const _root = Logger("root", WARNING, STDERR)
Logger(name::String;args...) = configure(Logger(name, WARNING, [STDERR], _root); args...)
Logger() = Logger("logger")

for (fn,lvl,clr) in ((:debug,    DEBUG,    :cyan),
                     (:info,     INFO,     :blue),
                     (:warn,     WARNING,  :magenta),
                     (:err,      ERROR,    :red),
                     (:critical, CRITICAL, :red))

    @eval function $fn(logger::Logger, msg...)
        if $lvl <= logger.level
            for output in logger.output
                logstring = string(strftime("%d-%b %H:%M:%S",time()),":",$lvl, ":",logger.name,":", msg...,"\n")
                if isa(output, Base.TTY)
                    Base.print_with_color($(Expr(:quote, clr)), output, logstring )
                elseif typeof(output) <: IO
                    print(output, logstring)
                    flush(output)
                else
                    log(output, $lvl, logger.name, msg...)
                end
            end
        end
    end

    @eval $fn(msg...) = $fn(_root, msg...)

end

function configure(logger=_root; args...)
    for (tag, val) in args
        if tag == :parent
            logger.parent = parent = val::Logger
            logger.level = parent.level
            logger.output = parent.output
        end
    end

    for (tag, val) in args
        tag == :io            ? typeof(val) <: AbstractArray ? (logger.output = val) :
                                                               (logger.output = [val::LogOutput]) :
        tag == :output        ? typeof(val) <: AbstractArray ? (logger.output = val) :
                                                               (logger.output = [val::LogOutput]) :
        tag == :filename      ? (logger.output = [open(val, "a")]) :
        tag == :level         ? (logger.level  = val::LogLevel) :
        tag == :override_info ? nothing :  # handled below
        tag == :parent        ? nothing :  # handled above
                                (Base.error("Logging: unknown configure argument \"$tag\""))
    end

    logger
end

override_info(;args...) = (:override_info, true) in args

macro configure(args...)
    _args = gensym()
    quote
        logger = Logging.configure($(args...))
        if Logging.override_info($(args...))
            function Base.info(msg::String...)
                Logging.info(Logging._root, msg...)
            end
        end
        include(joinpath(Pkg.dir("Logging"), "src", "logging_macros.jl"))
        logger
    end
end

end # module
