
"""
    AbstractData

    Data is used to keep information between different runs of an algorithm or between 
    runs of different algorithms. Data contains user data, such as models and formulations, 
    as well as computed data stored in units. 
"""
abstract type AbstractData end

getstoragedict(::AbstractData) = nothing
getmodel(::AbstractData) = nothing 
get_model_storage_dict(::AbstractData, ::AbstractModel) = nothing
store_records!(::AbstractData, ::RecordsVector) = nothing
check_records_participation(::AbstractData) = nothing

function getnicename(data::AbstractData) 
    model = getmodel(data)
    return string("data associated to model of type $(typeof(model)) with id $(getuid(model))")
end

function get_storage_container(data::AbstractData, pair::UnitTypePair)
    storagedict = getstoragedict(data)
    storagecont = get(storagedict, pair, nothing)
    if storagecont === nothing
        error(string("No storage unit for pair $pair in $(getnicename(data))"))                        
    end
    return storagecont
end

getunit(data::AbstractData, pair::UnitTypePair) = 
    getunit(get_storage_container(data, pair))

function reserve_for_writing!(data::AbstractData, pair::UnitTypePair) 
    TO.@timeit Coluna._to "Reserve for writing" begin
        reserve_for_writing!(get_storage_container(data, pair))   
    end
end

"""
    EmptyData
"""
struct EmptyData <: AbstractData end

"""
    ModelData

    Data for a single model. 
"""
mutable struct ModelData <: AbstractData
    model::AbstractModel
    storagedict::StorageDict
end

ModelData(model::AbstractModel) = ModelData(model, StorageDict())
ModelData(::Nothing) = EmptyData()

getstoragedict(data::ModelData) = data.storagedict
getmodel(data::ModelData) = data.model

function get_model_storage_dict(data::ModelData, model::AbstractModel)
    model == getmodel(data) && return getstoragedict(data)
    return nothing
end

function store_records!(data::ModelData, records::RecordsVector)
    storagedict = getstoragedict(data)
    for (FullType, storagecont) in storagedict
        recordid = store_record!(storagecont)
        push!(records, storagecont => recordid)
    end
end

function check_records_participation(data::ModelData)
    storagedict = getstoragedict(data)
    for (FullType, storagecont) in storagedict
        check_records_participation(storagecont)
    end
end

"""
    ReformData

    Data for reformulation. 
"""
mutable struct ReformData <: AbstractData
    reform::Reformulation
    storagedict::StorageDict
    masterdata::AbstractData # can be ModelData or EmptyData
    dw_pricing_datas::Dict{FormId, AbstractData} 
    benders_sep_datas::Dict{FormId, AbstractData} 
end

getstoragedict(data::ReformData) = data.storagedict
getmodel(data::ReformData) = data.reform
getreform(data::ReformData) = data.reform
getmasterdata(data::ReformData) = data.masterdata
get_dw_pricing_datas(data::ReformData) = data.dw_pricing_datas
get_benders_sep_datas(data::ReformData) = data.benders_sep_datas

function ReformData(reform::Reformulation)
    dw_pricing_datas = Dict{FormId, AbstractData}()
    sps = get_dw_pricing_sps(reform)
    for (spuid, spform) in sps
        if typeof(spform) == Reformulation
            dw_pricing_datas[spuid] = ReformData(spform)
        else
            dw_pricing_datas[spuid] = ModelData(spform)
        end
    end 

    benders_sep_datas = Dict{FormId, AbstractData}()
    sps = get_benders_sep_sps(reform)
    for (spuid, spform) in sps
        if typeof(spform) == Reformulation
            benders_sep_datas[spuid] = ReformData(spform)
        else
            benders_sep_datas[spuid] = ModelData(spform)
        end
    end

    return ReformData(
        reform, StorageDict(), ModelData(getmaster(reform)), dw_pricing_datas, benders_sep_datas
    )
end 

function get_model_storage_dict(data::ReformData, model::AbstractModel)
    if model == getmodel(data) 
        return getstoragedict(data)
    elseif model == getmodel(getmasterdata(data))
        return getstoragedict(getmasterdata(data))
    else
        for (formid, sp_data) in get_dw_pricing_datas(data)
            model = getmodel(sp_data) 
            return getstoragedict(sp_data)
        end
        for (formid, sp_data) in get_benders_sep_datas(data)
            model = getmodel(sp_data) 
            return getstoragedict(sp_data)
        end
    end
    return nothing
end

function store_records!(data::ReformData, records::RecordsVector)
    storagedict = getstoragedict(data)
    for (FullType, storagecont) in storagedict
        recordid = store_record!(storagecont)
        push!(records, (storagecont, recordid))
    end
    store_records!(getmasterdata(data), records)
    for (formid, sp_data) in get_dw_pricing_datas(data)
        store_records!(sp_data, records)
    end
    for (formid, sp_data) in get_benders_sep_datas(data)
        store_records!(sp_data, records)
    end 
end

function store_records!(data::ReformData)
    TO.@timeit Coluna._to "Store records" begin
        records = RecordsVector()
       store_records!(data, records)
    end       
    return records
end

function check_records_participation(data::ReformData)
    storagedict = getstoragedict(data)
    for (FullType, storagecont) in storagedict
        check_records_participation(storagecont)
    end
    check_records_participation(getmasterdata(data))
    for (formid, sp_data) in get_dw_pricing_datas(data)
        check_records_participation(sp_data)
    end
    for (formid, sp_data) in get_benders_sep_datas(data)
        check_records_participation(sp_data)
    end 
end
