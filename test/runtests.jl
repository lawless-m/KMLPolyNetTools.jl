using KMLPolynetTools
using Meshes
using Test

@testset "KMLPolynetTools.jl" begin
    @test KMLPolynetTools.remove_repeats([1,2,3,4,4,4,5,6,6,7,8,8,1]) == [1,2,3,4,5,6,7,8,1]
    @test sort(KMLPolynetTools.split_at_intersections([1,2,3,4,5,6,7,2,8,1]), lt=(a,b)->length(a)<length(b)) == [[1,2,8,1],[2,3,4,5,6,7,2]]
    @test sort(KMLPolynetTools.split_at_intersections([1,2,3,4,5,13,6,7,4,8,9,10,4,11,12,1]), lt=(a,b)->length(a)<length(b)) == [[4,8,9,10,4], [4,5,13,6,7,4], [1,2,3,4,11,12,1]]
    @test KMLPolynetTools.txtPoint2("1.2,3.2") == Point(1.2, 3.2)
end
