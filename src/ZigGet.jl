module ZigGet
###################################
export get_jsondata
export check_existing_version
export download_zig
export extract_zig
export get_zig
####################################
import HTTP
import JSON
import Dates
import Downloads
import CodecXz
import Tar
import SHA
#import Dates
import Dates: Date
import Dates: today
# import Dates: now
# import Dates: DateTime
#import Dates: Date
# import Dates: Day

#####################################
struct ZigVersions
    newest::String
    date::Date
    existing::Dict{String,String}
end



function get_jsondata()
    response = HTTP.get("https://ziglang.org/download/index.json")
    jsondata = JSON.parse(String(response.body))

    open("index.json", "w") do response
        JSON.print(response, jsondata)
    end
    return jsondata
end

########################################
#Downloads.download("https://ziglang.org/download/index.json", "index.json")
########################################


##########################################
function check_existing_version(version; nightlyversion="")
    """Check if the version already exists in the directory
    Nightly is only there for master version
    """
    zigdir = "/opt/zig"
    if !isdir(zigdir)
        mkdir(zigdir)
    end
    dirs = cd(readdir, zigdir)

    for di in dirs
        f = findfirst("-x86_64-", di)
        # ignore any files not containing -x86_64-
        if f === nothing
            continue
        end
        #@show di, f
        ver = di[(f[end]+1):end]

        if nightlyversion != ""
            if ver == nightlyversion
                return true
            end
        else
            if startswith(ver, version)
                return true
            end
        end
    end
    return false
end
##########################################
function communicate(cmd::Cmd, input)
    inp = Pipe()
    out = Pipe()
    err = Pipe()

    process = run(pipeline(cmd, stdin=inp, stdout=out, stderr=err), wait=false)
    close(out.in)
    close(err.in)

    stdout = @async String(read(out))
    stderr = @async String(read(err))
    write(process, input)
    close(inp)
    wait(process)
    return (
        stdout=fetch(stdout),
        stderr=fetch(stderr),
        code=process.exitcode
    )
end

#################################################
function download_zig(dat; zigdir="/opt/zig")
    zig_latest_url = dat["x86_64-linux"]["tarball"]
    zig_latest_sha = dat["x86_64-linux"]["shasum"]
    zigtarballname = split(zig_latest_url, "/")[end]
    zigtarballpath = joinpath(zigdir, zigtarballname)
    if !isfile(zigtarballpath)
        println("Downloading $zigtarballname")
        Downloads.download(zig_latest_url, zigtarballpath)
    end
    if !isfile(zigtarballpath)
        println("Error downloading $zigtarballname")
        return
    end
    println("Downloaded $zigtarballname")
    sha = open(zigtarballpath) do f
        SHA.sha2_256(f)
    end |> bytes2hex

    if sha != zig_latest_sha
        println("Error: SHA256 mismatch for $zigtarballname")
        return
    end
    println("SHA256 verified for $zigtarballname")
    return zigtarballpath
end

###################################################

function extract_zig(dat; zigdir="/opt/zig")

    zigtarballname = split(dat["x86_64-linux"]["tarball"], "/")[end]
    zigtarballpath = joinpath(zigdir, zigtarballname)
    zigtarball_uncompressed = split(zigtarballname, ".")[begin:(end-1)]
    zigtarball_uncompressed = join(zigtarball_uncompressed, ".")
    zigtarball_uncompressed = joinpath(zigdir, zigtarball_uncompressed)
    # @show zigtarballpath, zigtarballname
    # @show zigtarball_uncompressed

    println("Uncompressing $zigtarballname")
    input = open(zigtarballpath, "r")
    output = open(zigtarball_uncompressed, "w")
    stream = CodecXz.XzDecompressorStream(output)
    write(stream, input)
    close(stream)

    #remove the tar.xZ file
    rm(zigtarballpath)

    # untar
    zigdir_uncompressed = split(zigtarball_uncompressed, ".")[begin:(end-1)]
    zigdir_uncompressed = join(zigdir_uncompressed, ".")
    zigdir_uncompressed = joinpath(zigdir, zigdir_uncompressed)
    @show zigdir_uncompressed
    if isdir(zigdir_uncompressed)
        println("Directory $zigdir_uncompressed already exists.  Exiting.")
        return
    end

    # extract to a temporary directory
    dir = Tar.extract(zigtarball_uncompressed)
    # remove the tarball
    rm(zigtarball_uncompressed)

    # dir is a temporary directory of the contents of the tarball
    # move the contents to the zigdir
    tempdir_contents = readdir(dir)
    if length(tempdir_contents) > 1
        println("Error: More than one directory in $zigtarball_uncompressed")
        return
    end

    dir = joinpath(dir, tempdir_contents[1])
    dest = joinpath(zigdir, tempdir_contents[1])

    mv(dir, dest)
    println("\ncontents of $zigdir : ")
    for f in sort(readdir(zigdir))
        println(f) #
    end
    println()

    # add dest to update-altenatives --config zig
    println("Adding $dest/zig to alternatives")
    update_cmd = `sudo update-alternatives --install /usr/bin/zig zig $dest/zig 50`
    communicate(update_cmd, "")
    set_cmd = `sudo update-alternatives --set zig $dest/zig`
    communicate(set_cmd, "")

    println("Added new version. You may want to remove old versions.")

end

###################################

function cleanup_local_versions()

    listzig_cmd = `update-alternatives --list zig`
    sout, serr, cd = ZigGet.communicate(listzig_cmd, "")
    sout = split(sout, "\n")
    verss = Dict{Int,String}()
    for (i, ver) in enumerate(sout)
        if length(ver) > 0
            verss[i] = ver
            println(" $i : $ver ")
        end
    end
    println("Do you want to remove any of these versions? \n [ Space, then Enter, then enter digit(s)]!!!")

    n = readline()
    ns = []
    try
        ns = split(n)
        ns = parse.(Int, ns)
    catch e
        ns = split(n, ",")
        ns = parse.(Int, ns)
    end

    for n in ns
        if haskey(verss, n)
            println("Remove $(verss[n])? [y/N]")
            ans = readline()
            if ans == "y" || ans == "Y"
                fin = findlast("/zig", verss[n])
                if fin[1] > 2
                    dest = verss[n][1:fin[1]]
                    commadnd = `sudo update-alternatives --remove zig $(verss[n])`
                    sout, serr, cd = ZigGet.communicate(commadnd, "")
                end
                rm(dest, recursive=true)
            end
        end
    end

    println(" $n.")

end



#################################
function get_zig(myversion="master")

    # jsondata =  open("index.json","r") do f
    #     JSON.parse(f) 
    # end  #
    jsondata = get_jsondata()

    dat = nothing

    try
        dat = jsondata[myversion]
    catch
        println("Error: Version $myversion not found in index.json")
        return
    end

    if dat == nothing
        println("Error: Version $myversion not found in index.json")
        return
    end

    date = dat["date"] |> Date

    nightlyversion = ""
    if myversion == "master"
        # Only master has a version, due to nightly builds
        nightlyversion = dat["version"]
        println("Latest version $(nightlyversion) released on $(date), $(date - Dates.today()) days ago")
    else
        println("Version $(myversion) released on $(date), $(date - Dates.today()) days ago")
    end

    # check for existing version
    if check_existing_version(myversion; nightlyversion=nightlyversion)
        println("Latest version $myversion already exists.  Exiting.")
        return # exit(0)
    end

    download_zig(dat; zigdir="/opt/zig")
    extract_zig(dat; zigdir="/opt/zig")
    #println("zig url = $(zig_latest_url) ")#Downloading latest version $version")
    cleanup_local_versions()
end
#################################################

end # module ZigGet
