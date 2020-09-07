using Parquet
using Test
using Dates

function test_load(file::String)
    p = ParFile(file)
    println("loaded $file")
    @test isa(p.meta, Parquet.FileMetaData)

    rgs = rowgroups(p)
    @test length(rgs) > 0

    cnames = colnames(p)
    @test length(cnames) > 0
    println("\tcolumns: $cnames")

    for rg in rgs
        ccs = columns(p, rg)
        println("\treading row group with $(length(ccs)) column chunks")

        for cc in ccs
            npages = 0
            ccp = Parquet.ColumnChunkPages(p, cc)
            result = iterate(ccp)
            npages = 0
            ncompressedbytes = 0
            nuncompressedbytes = 0
            while result !== nothing
                page,nextpos = result
                result = iterate(ccp, nextpos)
                npages += 1
                ncompressedbytes += Parquet.page_size(page.hdr)
                nuncompressedbytes += page.hdr.uncompressed_page_size
            end
            println("\tread column chunk with $npages pages, $ncompressedbytes compressed, $nuncompressedbytes uncompressed")
        end
    end


    iob = IOBuffer()
    show(iob, p)
    sb = take!(iob)
    @test !isempty(sb)
    println("\t" * String(sb))

    println("\tsuccess")
end

function test_load_all_pages()
    testfolder = joinpath(@__DIR__, "parquet-compatibility")
    for encformat in ("SNAPPY", "GZIP", "NONE")
        for fname in ("nation", "customer")
            testfile = joinpath(testfolder, "parquet-testdata", "impala", "1.1.1-$encformat", "$fname.impala.parquet")
            test_load(testfile)
        end
    end

    testfolder = joinpath(@__DIR__, "julia-parquet-compatibility")
    for encformat in ("ZSTD", "SNAPPY", "GZIP", "NONE")
        for fname in ("nation", "customer")
            testfile = joinpath(testfolder, "Parquet_Files", "$(encformat)_pandas_pyarrow_$(fname).parquet")
            test_load(testfile)
        end
    end
end

function test_load_boolean_and_ts()
    println("testing booleans and timestamps...")
    p = ParFile(joinpath(@__DIR__, "booltest", "alltypes_plain.snappy.parquet"))

    rg = rowgroups(p)
    @test length(rg) == 1
    cc = columns(p, 1)
    @test length(cc) == 11
    cnames = colnames(p)
    @test length(cnames) == length(cc)
    @test cnames[2] == ["bool_col"]

    rc = RecordCursor(p; rows=1:2, colnames=colnames(p))
    @test length(rc) == 2
    @test eltype(rc) == NamedTuple{(:id, :bool_col, :tinyint_col, :smallint_col, :int_col, :bigint_col, :float_col, :double_col, :date_string_col, :string_col, :timestamp_col),Tuple{Union{Missing, Int32},Union{Missing, Bool},Union{Missing, Int32},Union{Missing, Int32},Union{Missing, Int32},Union{Missing, Int64},Union{Missing, Float32},Union{Missing, Float64},Union{Missing, Array{UInt8,1}},Union{Missing, Array{UInt8,1}},Union{Missing, DateTime}}}

    values = collect(rc)
    @test [v.bool_col for v in values] == [true,false]
    @test [v.timestamp_col for v in values] == [DateTime("2009-04-01T12:00:00"), DateTime("2009-04-01T12:01:00")]

    cc = BatchedColumnsCursor(p)
    values, _state = iterate(cc)
    @test values.timestamp_col == [DateTime("2009-04-01T12:00:00"), DateTime("2009-04-01T12:01:00")]

    p = ParFile(joinpath(@__DIR__, "booltest", "alltypes_plain.snappy.parquet"); map_logical_types=Dict(["date_string_col"]=>(String,logical_string)))
    rc = RecordCursor(p; rows=1:2, colnames=colnames(p))
    values = collect(rc)
    @test [v.date_string_col for v in values] == ["04/01/09", "04/01/09"]

    cc = BatchedColumnsCursor(p)
    values, _state = iterate(cc)
    @test values.date_string_col == ["04/01/09", "04/01/09"]

    p = ParFile(joinpath(@__DIR__, "booltest", "alltypes_plain.snappy.parquet"); map_logical_types=Dict(["timestamp_col"]=>(DateTime,(v)->logical_timestamp(v; offset=Dates.Second(30)))))
    rc = RecordCursor(p; rows=1:2, colnames=colnames(p))
    values = collect(rc)
    @test [v.timestamp_col for v in values] == [DateTime("2009-04-01T12:00:30"), DateTime("2009-04-01T12:01:30")]

    cc = BatchedColumnsCursor(p)
    values, _state = iterate(cc)
    @test values.timestamp_col == [DateTime("2009-04-01T12:00:30"), DateTime("2009-04-01T12:01:30")]
    #dlm,headers=readdlm("booltest/alltypes.csv", ','; header=true)
    #@test [v.bool_col for v in values] == dlm[:,2]  # skipping for now as this needs additional dependency on DelimitedFiles
end

function test_load_nested()
    println("testing nested columns...")
    p = ParFile(joinpath(@__DIR__, "nested", "nested1.parquet"))

    @test nrows(p) == 100
    @test ncols(p) == 5

    rc = RecordCursor(p)
    @test length(rc) == 100
    @test eltype(rc) == NamedTuple{(:_adobe_corpnew,),Tuple{NamedTuple{(:id, :vocab, :frequency, :max_len, :reduced_max_len),Tuple{Union{Missing, Int32},Union{Missing, String},Union{Missing, Int32},Union{Missing, Float64},Union{Missing, Int32}}}}}

    values = Any[]
    for rec in rc
        push!(values, rec)
    end

    v = values[1]._adobe_corpnew
    @test v.frequency == 3
    @test v.id == 1375
    @test v.max_len == 64192.0
    @test v.reduced_max_len == 64
    @test v.vocab == "10385911_a"

    v = values[100]._adobe_corpnew
    @test v.frequency == 61322
    @test v.id == 724
    @test v.max_len == 64192.0
    @test v.reduced_max_len == 64
    @test v.vocab == "12400277_a"

    p = ParFile(joinpath(@__DIR__, "nested", "nested.parq"))

    @test nrows(p) == 10
    @test ncols(p) == 1

    rc = RecordCursor(p)
    @test length(rc) == 10
    @test eltype(rc) == NamedTuple{(:nest,),Tuple{Union{Missing, NamedTuple{(:thing,),Tuple{Union{Missing, NamedTuple{(:list,),Tuple{Array{NamedTuple{(:element,),Tuple{Union{Missing, String}}},1}}}}}}}}}

    values = collect(rc)
    v = first(values)
    @test length(v.nest.thing.list) == 2
    @test v.nest.thing.list[1].element == "hi"
    v = last(values)
    @test length(v.nest.thing.list) == 2
    @test v.nest.thing.list[1].element == "world"
end

function test_load_multiple_rowgroups()
    println("testing multiple rowgroups...")
    p = ParFile(joinpath(@__DIR__, "rowgroups", "multiple_rowgroups.parquet"))

    @test nrows(p) == 100
    @test ncols(p) == 12

    rc = RecordCursor(p)
    @test length(rc) == 100
    vals = collect(rc)
    @test length(vals) == 100
    @test vals[1].int64 == vals[51].int64
    @test vals[1].int32 == vals[51].int32

    cc = BatchedColumnsCursor(p)
    @test length(cc) == 2
    colvals = collect(cc)
    @test length(colvals) == 2
    @test length(colvals[1].int32) == 50
end

test_load_all_pages()
test_load_boolean_and_ts()
test_load_nested()
test_load_multiple_rowgroups()
