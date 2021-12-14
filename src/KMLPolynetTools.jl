module KMLPolynetTools

export Points, Poly, Polynet, extract_polynet_from_kml, load, save, scaled_svg, get_or_cache_polynet

using Serialization
using LightXML
using SVG
using Pipe

struct Points 
    d::Dict{String, Int}
    xs::Vector{Float64}
    ys::Vector{Float64}
    Points() = new(Dict{String, Int}(), Vector{Float64}(), Vector{Float64}())
end

function pointn(ps::Points, txt)
    n = get(ps.d, txt, 0)
    if n == 0
        n = length(ps.d) + 1
        ps.d[txt] = n 
        fpair = split(txt, ",")
        push!(ps.xs, parse(Float64, fpair[1]))
        push!(ps.ys, parse(Float64, fpair[2]))
    end
    n
end

struct Poly
    meta
    perimeter
end

struct Polynet
    points
    polys
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

function save(fn, pm::Polynet)::Polymesh
    open(fn, "w+") do io
        println(stderr, "ser")
        serialize(io, pm)
    end
    pm
end

function scaled_svg(polymesh, filename; inhtml=true)
    local xtreme, ytreme, xs, ys
    xtreme = extrema(polymesh.points.xs)
    ytreme = extrema(polymesh.points.ys)
    xmx = xtreme[2] - xtreme[1]
    ymx = ytreme[2] - ytreme[1]
    scale = 800 / min(xmx, ymx)
    xmx *= scale
    ymx *= scale
    fx = x -> round(Int, scale * (x - xtreme[1]))
    fy = y -> round(Int, ymx - scale * (y - ytreme[1]))

    xs = map(fx, polymesh.points.xs)
    ys = map(fy, polymesh.points.ys)

    asSvg(xs, ys, polymesh.polys, filename, 800, 1200, "0 0 $xmx $ymx"; inhtml)
end

function asSvg(xs, ys, polys::Vector{Poly}, filename, width, height, viewbox; inhtml=true)
    w = (io, svg)->foreach(poly->write(io, Polyline(xs[poly.perimeter], ys[poly.perimeter])), polys)
    SVG.write(filename, SVG.Svg(), width, height ; viewbox, inhtml, objwrite_fn=w)
end

function extract_polynet_from_kml(xdoc)
    polys = Vector{Poly}()
    points = Points()
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
            for mg in get_elements_by_tagname(pk, "MultiGeometry")
                for pol in get_elements_by_tagname(mg, "Polygon")
                    for bound in get_elements_by_tagname(pol, "outerBoundaryIs")
                        for lr in get_elements_by_tagname(bound, "LinearRing")
                            for cords in get_elements_by_tagname(lr, "coordinates")
                                push!(polys, Poly(meta, map(p->pointn(points, p), split(content(cords), " "))))
                            end
                        end
                    end
                end
            end
        end
    end
    Polynet(points, polys)
end

function get_or_cache_polynet(kml, cachefn)
    pmesh = load(cachefn)
    if pmesh === nothing        
        pmesh = @pipe parse_file(kml) |> extract_polynet_from_kml |> save(cachefn, _)
    end
    pmesh
end


###
end