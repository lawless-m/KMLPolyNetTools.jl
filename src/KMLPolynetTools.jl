module KMLPolynetTools

using Meshes

#types
export Points, Poly, Polynet

#methods
export extract_polynet_from_kml, load, save, scaled_svg
export get_or_cache_polynet
export shared_points

# dependencies
using Serialization
using LightXML
using SVG
using Pipe

struct Points
    p2s::Vector{Point2}
    d::Dict{Point2, Int}
    Points() = new(Vector{Point2}(), Dict{Point2, Int}())
    Points(p2s, d) = new(p2s, d)
end

Base.copy(p::Points) = Points(copy(p.p2s), copy(p.d))

struct Region
    meta::Dict
    pointNs::Vector{Vector{Int}}
    Region(m::Dict) = new(m, Vector{Vector{Int}}())
end

struct Polynet
    points::Points
    regions::Vector{Region}
end

Base.copy(p::Polynet) = Polynet(copy(p.points), copy(p.regions))

Base.copy(r::Region) = Region(copy(r.meta), copy(r.polys))

pArea(point2s::Vector{Point2}, perimeter::Vector{Int}) = PolyArea(point2s[perimeter])

struct PolyAreaRegion
    meta::Dict
    polyareas::Vector{PolyArea}
    PolyAreaRegion(p2s, r::Region) = new(r.meta, map(pns->PolyArea(p2s[pns]), r.pointNs))
end

struct PolyAreaNet
    points::Points
    regions::Vector{PolyAreaRegion}
    PolyAreaNet(pnet::Polynet) = new(pnet.points, map(r->PolyAreaRegion(pnet.points.p2s, r), pnet.regions))
end


function split_at_intersections(pointNs::Vector{Int})
    match(n) = return t->t==n
    polys = Vector{Int}[]
    poly = Int[]
    s = 1
    i = 1
    while i < length(pointNs)
        n = findlast(match(pointNs[i]), pointNs[i+1:end-1])
        if n === nothing
            push!(poly, pointNs[i])
        else
            push!(poly, pointNs[i])
            append!(polys, split_at_intersections(pointNs[i:i+n]))
            i = i + n 
        end 
        i += 1
    end
    push!(poly, pointNs[end])
    push!(polys, poly)
    polys
end

function add_perimeters!(r::Region, pointNs::Vector{Int})
    for ps in split_at_intersections(remove_repeats(pointNs))
        if length(ps) > 3
            push!(r.pointNs, ps)
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

function txtPoint2(txt; digits=5)
    Point2(map(t->round(parse(Float64, t); digits), split(txt, ",")))
end

function pointn(ps::Points, txt; digits=5)
    p2 = txtPoint2(txt; digits)
    n = get(ps.d, p2, 0)
    if n == 0
        n = length(ps.p2s) + 1
        ps.d[p2] = n
        push!(ps.p2s, p2)
    end
    n
end

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

function scaled_svg(pnet, filename; inhtml=true, digits=3, colorfn=nothing)
    cs = coordinates.(pnet.points.p2s)
    xs = map(c->c[1], cs)
    ys = map(c->c[2], cs)
    xtreme = extrema(xs)
    ytreme = extrema(ys)
    xmx = xtreme[2] - xtreme[1]
    ymx = ytreme[2] - ytreme[1]
    scale = 800 / min(xmx, ymx)
    xmx *= scale
    ymx *= scale
    fx = x -> round(scale * (x - xtreme[1]); digits)
    fy = y -> round(ymx - scale * (y - ytreme[1]); digits)

    xs = map(fx, xs)
    ys = map(fy, ys)

    asSvg(xs, ys, pnet.regions, filename, 800, 1200, "0 0 $xmx $ymx"; inhtml, colorfn)
end

function asSvg(xs, ys, regions::Vector{Region}, filename, width, height, viewbox; colorfn=nothing, inhtml=true)
    
    if colorfn === nothing
        colorfn = (m)->"none"
    end
   
    function pline(meta, pointNs)
        xy = remove_repeats(map(n->(xs[n], ys[n]), pointNs))
        nxs = Vector{eltype(xs)}(undef, length(xy))
        nys = Vector{eltype(ys)}(undef, length(xy))
        for (i, (x,y)) in enumerate(xy)
            nxs[i] = x
            nys[i] = y
        end
        Polyline(nxs, nys, style=Style(;fill=colorfn(meta)))
    end
    w = (io, svg) -> foreach(r->foreach(ps->write(io, pline(r.meta, ps)), r.pointNs), regions)
    SVG.write(filename, SVG.Svg(), width, height ; viewbox, inhtml, objwrite_fn=w)
end

function polynet_from_kml(xdoc; digits=5)
    points = Points()
    regions = Region[]
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
            region = Region(meta)
            for mg in get_elements_by_tagname(pk, "MultiGeometry")
                for pol in get_elements_by_tagname(mg, "Polygon")
                    for bound in get_elements_by_tagname(pol, "outerBoundaryIs")
                        for lr in get_elements_by_tagname(bound, "LinearRing")
                            for cords in get_elements_by_tagname(lr, "coordinates")
                                add_perimeters!(region, map(p->pointn(points, p; digits), split(content(cords), " ")))
                            end
                        end
                    end
                end
            end
            push!(regions, region)
        end
    end
    Polynet(points, regions)
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

function shared_points(pnet)
    used = zeros(Int, length(pnet.points.xs))
    for poly in pnet.polys
        for pnt in poly.perimeter
            used[pnt] += 1
        end
    end
    used
end

function SMesh(pnet::Polynet)
    points = Points2(pnet)
    perims = Vector{Tuple}()
    for reg in pnet.regions
        for perim in reg.pointNs
            push!(perims, Tuple(perim))
        end 
    end
    SimpleMesh(points, map(p->connect(p, Ngon), perims))
end

triangulate(pnet::Polynet) = triangulate(PolyAreaNet(pnet))

function triangulate(panet::PolyAreaNet)
    triregs = Vector()
    for reg in panet.regions
        tris = Vector()
        for pa in reg.polyareas
            try 
                push!(tris, discretize(pa, Dehn1899()))
            catch
            end
        end
        push!(triregs, (reg.meta, tris))
    end
    triregs
end

#==
using KMLPolynetTools
pnet = get_or_cache_polynet("/home/matt/wren/UkGeoData/uk.kml", "/home/matt/wren/UkGeoData/polynet_2dp.sj");
panet = KMLPolynetTools.PolyAreaNet(pnet);
tris =  KMLPolynetTools.triangulate(panet);
==#
###
end