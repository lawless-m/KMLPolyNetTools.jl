using KMLPolynetTools
using Test

@testset "KMLPolynetTools.jl" begin
    @test KMLPolynetTools.remove_repeats_and_loops([1,2,3,4,4,4,5,6,6,7,8,8,1]) == [1,2,3,4,5,6,7,8,1]
    @test KMLPolynetTools.remove_repeats_and_loops([1,2,3,4,4,4,5,6,6,7,2,8,8,1]) == [1,2,8,1]
    @test KMLPolynetTools.remove_repeats_and_loops([1,2,3,4,1,5,6,1]) == [1,5,6,1]
end
