module KMLPolynetTools

export Points, Poly, Polynet, extract_polynet_from_kml, load, save, scaled_svg, get_or_cache_polynet

export shared_points

using Serialization
using LightXML
using SVG
using Pipe

const PointXY = Tuple{Float64, Float64} # (x,y)

struct Points 
    d::Dict{PointXY, Int}
    xs::Vector{Float64}
    ys::Vector{Float64}
    Points() = new(Dict{PointXY, Int}(), Vector{Float64}(), Vector{Float64}())
    Points(d, xs, ys) = new(d, xs, ys)
end

Base.copy(p::Points) = Points(copy(p.d), copy(p.xs), copy(p.ys))

struct Polynet
    points
    polys
end

Base.copy(p::Polynet) = Polynet(copy(p.points), copy(p.polys))

struct Poly
    meta
    perimeter
    function Poly(m, p)
        pp = Vector{Int}(undef, length(p))
        lastp = 0
        k = 0
        for i in 1:length(p)
            if p[i] != lastp
                k += 1
                lastp = pp[k] = p[i]
            end
        end
        new(m, pp[1:k])
    end
end

Base.copy(p::Poly) = Poly(copy(p.meta), copy(p.perimeter))

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

scaled_svg(pnet, filename; inhtml=true) = scaled_svg(pnet.points.xs, pnet.points.ys, pnet.polys, filename; inhtml)

function scaled_svg(unscaled_xs, unscaled_ys, polys, filename; inhtml=true, digits=3)
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

    asSvg(xs, ys, polys, filename, 800, 1200, "0 0 $xmx $ymx"; inhtml)
end

function asSvg(xs, ys, polys::Vector{Poly}, filename, width, height, viewbox; inhtml=true)
    w = (io, svg)->foreach(poly->write(io, Polyline(xs[poly.perimeter], ys[poly.perimeter])), polys)
    SVG.write(filename, SVG.Svg(), width, height ; viewbox, inhtml, objwrite_fn=w)
end

function extract_polynet_from_kml(xdoc; digits=5)
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
                                poly = Poly(meta, map(p->pointn(points, p; digits), split(content(cords), " ")))
                                if length(poly.perimeter) > 3
                                    push!(polys, poly)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    Polynet(points, polys)
end

function get_or_cache_polynet(kml, cachefn; digits=5, force=false)
    pnet::Union{Polynet, Nothing} = nothing
    if !force
        pnet = load(cachefn)
    end
    if pnet === nothing        
        pnet = @pipe parse_file(kml) |> extract_polynet_from_kml(_; digits) |> save(cachefn, _)
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

###
end