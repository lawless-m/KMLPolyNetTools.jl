module KMLPolynetTools

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

# goo
const PointXY = Tuple{Float64, Float64} # (x,y)

struct Points 
    d::Dict{PointXY, Int}
    xs::Vector{Float64}
    ys::Vector{Float64}
    Points() = new(Dict{PointXY, Int}(), Vector{Float64}(), Vector{Float64}())
    Points(d, xs, ys) = new(d, xs, ys)
end

Base.copy(p::Points) = Points(copy(p.d), copy(p.xs), copy(p.ys))

struct Region
    meta::Dict
    pointNs::Vector{Vector{Int}}
    Region(m::Dict) = new(m, Vector{Vector{Int}}())
end

Base.copy(r::Region) = Region(copy(r.meta), copy(r.polys))

function add_perimeter!(r::Region, pointNs::Vector{Int})
    ps = remove_repeats(pointNs)
    if length(ps) > 3
        push!(r.pointNs, ps)
    end
    r
end

struct Polynet
    points::Points
    regions::Vector{Region}
end

Base.copy(p::Polynet) = Polynet(copy(p.points), copy(p.regions))

function remove_repeats_and_loops(src) ## removes geography
    # src = [1,2,3,4,4,4,5,6,6,7,8,8,1]
    # tgt = [1,2,3,4,5,6,7,8,1]
    # src = [1,2,3,4,4,4,5,6,6,7,2,8,8,1]
    # tgt = [1,2,8,1]

    match(n) = return t->t==n

    tgt = Vector{eltype(src)}(undef, length(src))
    srci = 1
    tgti = 0

    while srci < length(src) && tgti < length(tgt)
        n = findlast(match(src[srci]), src[srci+1:end])
        tgti += 1
        if n == nothing || (srci == 1 && n == length(src)-1)
            tgt[tgti] = src[srci]
        else
            srci += n
            tgt[tgti] = src[srci]
        end
        srci += 1
    end
    tgti += 1
    tgt[tgti] = src[end]
    tgt[1:tgti]
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


function txtXY(txt; digits=5)::PointXY
    Tuple(map(t->round(parse(Float64, t); digits), split(txt, ",")))
end

function pointn(ps::Points, txt; digits=5)
    xy = txtXY(txt; digits)
    n = get(ps.d, xy, 0)
    if n == 0
        n = length(ps.d) + 1
        ps.d[xy] = n
        push!(ps.xs, xy[1])
        push!(ps.ys, xy[2])
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

scaled_svg(pnet, filename; inhtml=true, digits=3) = scaled_svg(pnet.points.xs, pnet.points.ys, pnet.regions, filename; inhtml, digits)

function scaled_svg(unscaled_xs, unscaled_ys, regions, filename; inhtml=true, digits=3)
    local xtreme, ytreme, xs, ys
    xtreme = extrema(unscaled_xs)
    ytreme = extrema(unscaled_ys)
    xmx = xtreme[2] - xtreme[1]
    ymx = ytreme[2] - ytreme[1]
    scale = 800 / min(xmx, ymx)
    xmx *= scale
    ymx *= scale
    fx = x -> round(scale * (x - xtreme[1]); digits)
    fy = y -> round(ymx - scale * (y - ytreme[1]); digits)

    xs = map(fx, unscaled_xs)
    ys = map(fy, unscaled_ys)

    asSvg(xs, ys, regions, filename, 800, 1200, "0 0 $xmx $ymx"; inhtml)
end

function asSvg(xs, ys, regions::Vector{Region}, filename, width, height, viewbox; inhtml=true)
    function pline(pointNs)
        xy = remove_repeats(map(n->(xs[n], ys[n]), pointNs))
        nxs = Vector{eltype(xs)}(undef, length(xy))
        nys = Vector{eltype(ys)}(undef, length(xy))
        for (i, (x,y)) in enumerate(xy)
            nxs[i] = x
            nys[i] = y
        end
        Polyline(nxs, nys)
    end
    w = (io, svg) -> foreach(r->foreach(ps->write(io, pline(ps)), r.pointNs), regions)
    SVG.write(filename, SVG.Svg(), width, height ; viewbox, inhtml, objwrite_fn=w)
end

function points_regions_from_kml(xdoc; digits=5)
    points = Points()
    regions = Region[]
    for fr in get_elements_by_tagname(get_elements_by_tagname(root(xdoc), "Document")[1], "Folder")
        for pk in get_elements_by_tagname(fr, "Placemark")
            meta = Dict{String, Union{String, Float64}}()
            for ed in get_elements_by_tagname(pk, "ExtendedData")
                for scd in get_elements_by_tagname(ed, "SchemaData")
                    for sd in get_elements_by_tagname(scd, "SimpleData")
                        for a in attributes(sd)
                            if name(a) == "name"
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
                                add_perimeter!(region, map(p->pointn(points, p; digits), split(content(cords), " ")))
                            end
                        end
                    end
                end
            end
            push!(regions, region)
        end
    end
    points, regions
end

function get_or_cache_polynet(kml, cachefn; digits=5, force=false)
    pnet::Union{Polynet, Nothing} = nothing
    if !force
        pnet = load(cachefn)
    end
    if pnet === nothing        
        points, places = @pipe parse_file(kml) |> points_places_from_kml
        polys = polys_from_places(places; digits)
        pnet = Polynet(polys, places)
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
#==
using KMLPolynetTools
kml = "/home/matt/wren/UkGeoData/uk.kml";
pnet = Polynet(KMLPolynetTools.points_regions_from_kml(KMLPolynetTools.parse_file(kml); digits=2)...)
KMLPolynetTools.scaled_svg(pnet, "round_regions.html"; digits=0);
==#
###
end