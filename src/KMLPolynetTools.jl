module KMLPolynetTools

using Meshes

#types
export Polynet, Region, triangulate, bbox

#methods
export extract_polynet_from_kml, load, save, scaled_svg
export get_or_cache_polynet
export shared_points

# dependencies
using Serialization
using LightXML
using SVG
using Pipe

struct Region{T}
    meta::Dict
    areas::Vector{T}
    Region{PolyArea}(m::Dict) = new{PolyArea}(m, Vector{PolyArea}())
    Region{PolyArea}(m::Dict, as::Vector{PolyArea}) = new{PolyArea}(m, as)
    Region{SimpleMesh}(m::Dict) = new{SimpleMesh}(m, Vector{SimpleMesh}())
    Region{SimpleMesh}(m::Dict, as::Vector{SimpleMesh}) = new{SimpleMesh}(m, as)
end

const Polynet{T} = Vector{Region{T}}

Base.copy(r::Region) = Region(copy(r.meta), copy(r.areas))

function split_at_intersections(points)
    match(n) = return t->t==n
    polys = Vector{typeof(points)}()
    poly = Vector{eltype(points)}()
    s = 1
    i = 1
    while i < length(points)
        n = findlast(match(points[i]), points[i+1:end-1])
        if n === nothing
            push!(poly, points[i])
        else
            push!(poly, points[i])
            append!(polys, split_at_intersections(points[i:i+n]))
            i = i + n 
        end 
        i += 1
    end
    push!(poly, points[end])
    push!(polys, poly)
    polys
end

function add_perimeters!(r::Region, points)
    for poly in split_at_intersections(remove_repeats(points))
        if length(poly) > 3
            push!(r.areas, PolyArea(poly))
        end
    end
    r
end

function remove_repeats(src)
    # src = [1,2,3,4,4,4,5,6,6,7,8,8,1]
    # tgt = [1,2,3,4,5,6,7,8,1]

    tgt = Vector{eltype(src)}(undef, length(src))
    srci = 1
    tgti = 0
    lastn = 0
    while srci < length(src) 
        if src[srci] != lastn
            tgti += 1
            lastn = tgt[tgti] = src[srci]
        end
        srci += 1
    end
    tgti += 1
    tgt[tgti] = src[end]
    tgt[1:tgti]
end

txtPoint2(txt; digits=5) = Point2(map(t->round(parse(Float64, t); digits), split(txt, ",")))

function load(fn)::Union{Polynet, Nothing}
    pm = nothing
    if isfile(fn) && filesize(fn) > 0
        open(fn, "r") do io
            pm = deserialize(fn)
        end
    end
    pm
end

function save(fn, pm::Polynet)::Polynet
    open(fn, "w+") do io
        serialize(io, pm)
    end
    pm
end

import Meshes.boundingbox

boundingbox(pnet::Polynet{PolyArea}) = boundingbox(map(boundingbox, filter(a->length(a) > 0, map(r->r.areas, pnet))))

#boundingbox(sms::Vector{SimpleMesh}) = map(boundingbox, sms)

boundingbox(mnet::Polynet{SimpleMesh}) = boundingbox(map(boundingbox, Iterators.flatten(filter(m->length(m) > 0, map(r->r.areas, mnet)))))

function scaled_svg(pnet, width, height, filename; inhtml=true, digits=3, colorfn=nothing)
    bbx = boundingbox(pnet)
    xmin, ymin = coordinates(bbx.min)
    xmax, ymax = coordinates(bbx.max)
    xmx = xmax - xmin
    ymx = ymax - ymin
    scale = min(width, height) / min(xmx, ymx)
    xmx *= scale
    ymx *= scale
    fx = x -> round(scale * (x - xmin); digits)
    fy = y -> round(ymx - scale * (y - ymin); digits)

    asSvg(pnet, width, height, filename; fx, fy, xmx, ymx, inhtml, colorfn)
end

function asSvg(pnet::Polynet{PolyArea}, width, height, filename; fx=identity, fy=identity, xmx=0, ymx=0, colorfn=nothing, inhtml=true)
    if xmx == 0
        xmx = width
    end
    if ymx == 0
        ymx = height
    end    
    if colorfn === nothing
        colorfn = (m)->"none"
    end
   
    pline(meta, polyarea) = Polyline(coordinates.(polyarea.outer.vertices); fx, fy, style=Style(;fill=colorfn(meta)))
    w = (io, svg) -> foreach(region->
                        foreach(polya->
                            write(io, pline(r.meta, polya))
                          , region.areas)
                    , pnet)
    SVG.write(filename, SVG.Svg(), width, height ; viewbox="0 0 $xmx $ymx", inhtml, objwrite_fn=w)
end

function asSvg(mnet::Polynet{SimpleMesh}, width, height, filename; fx=identity, fy=identity, xmx=0, ymx=0, colorfn=nothing, inhtml=true)
    if xmx == 0
        xmx = width
    end
    if ymx == 0
        ymx = height
    end    
    if colorfn === nothing
        colorfn = (m)->"none"
    end

    function pline(meta, tri)
        coords = coordinates.(vertices(tri))
        Polyline(vcat(coords, [coords[1]]); fx, fy, style=Style(;fill=colorfn(meta)))
    end
    w = (io, svg) -> foreach(reg->foreach(smesh->foreach(tri->write(io, pline(reg.meta, tri)), smesh), reg.areas), mnet) 
    SVG.write(filename, SVG.Svg(), width, height ; viewbox="0 0 $xmx $ymx", inhtml, objwrite_fn=w)
end

function polynet_from_kml(xdoc; digits=5)
    pnet = Polynet{PolyArea}()
    for fr in get_elements_by_tagname(get_elements_by_tagname(root(xdoc), "Document")[1], "Folder")
        for pk in get_elements_by_tagname(fr, "Placemark")
            meta = Dict{String, Union{String, Float64}}()
            for ed in get_elements_by_tagname(pk, "ExtendedData")
                for scd in get_elements_by_tagname(ed, "SchemaData")
                    for sd in get_elements_by_tagname(scd, "SimpleData")
                        for a in attributes(sd)
                            if LightXML.name(a) == "name"
                                meta[value(a)] = content(sd)
                            end
                        end
                    end
                end
            end
            region = Region{PolyArea}(meta)
            for mg in get_elements_by_tagname(pk, "MultiGeometry")
                for pol in get_elements_by_tagname(mg, "Polygon")
                    for bound in get_elements_by_tagname(pol, "outerBoundaryIs")
                        for lr in get_elements_by_tagname(bound, "LinearRing")
                            for cords in get_elements_by_tagname(lr, "coordinates")
                                add_perimeters!(region, map(t->txtPoint2(t; digits), split(content(cords), " ")))
                            end
                        end
                    end
                end
            end
            push!(pnet, region)
        end
    end
    pnet
end

function get_or_cache_polynet(kml, cachefn; digits=5, force=false)
    pnet::Union{Polynet, Nothing} = nothing
    if !force
        pnet = load(cachefn)
    end
    if pnet === nothing        
        pnet = polynet_from_kml(parse_file(kml); digits)
        save(cachefn, pnet)
    end
    pnet
end

function triangulate(pnet::Polynet)
    meshnet = Polynet{SimpleMesh}()
    for reg in pnet
        meshes = Vector{SimpleMesh}()
        for pa in reg.areas
            try 
                push!(meshes, discretize(pa, Dehn1899()))
            catch
                nothing
            end
        end
        push!(meshnet, Region{SimpleMesh}(reg.meta, meshes))
    end
    meshnet
end


#==
using KMLPolynetTools
pnet = get_or_cache_polynet("/home/matt/wren/UkGeoData/uk.kml", "/home/matt/wren/UkGeoData/polynet_2dp.sj");

==#
###
end