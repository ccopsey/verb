package verb.core;

import verb.core.types.TriSegmentIntersection;
import verb.core.types.Ray;
import verb.core.types.CurveTriPoint;
import verb.core.types.CurveCurveIntersection;
import verb.core.types.IBoundingBoxTree;
import verb.core.types.LazyPolylineBoundingBoxTree;
import verb.core.types.PolylineMeshIntersection;
import verb.core.types.PolylineData;
import verb.core.types.CurveSurfaceIntersection;
import verb.core.types.LazySurfaceBoundingBoxTree;
import verb.core.types.LazyCurveBoundingBoxTree;
import verb.core.types.Interval;
import verb.core.types.LazyMeshBoundingBoxTree;
import verb.core.types.MeshIntersectionPoint;
import verb.core.types.SurfaceSurfaceIntersectionPoint;
import verb.core.types.SurfaceData;
import verb.core.KdTree.KdPoint;
import verb.core.types.AdaptiveRefinementNode.AdaptiveRefinementOptions;
import verb.core.types.BoundingBoxNode;
import verb.core.types.Pair;
import verb.core.Mat.Vector;
import verb.core.types.MeshData;
import verb.core.types.CurveData;

using verb.core.ArrayExtensions;

@:expose("core.Intersect")
class Intersect {

    //
    // Intersect two NURBS surfaces, yielding a list of curves
    //
    // **params**
    // + SurfaceData for the first surface
    // + SurfaceData for the second
    //
    // **returns**
    // + array of CurveData objects
    //
    public static function surfaces( surface0 : SurfaceData, surface1 : SurfaceData, tol : Float) : Array<CurveData> {

        // 1) tessellate the two surfaces
        var tess1 = Tess.rationalSurfaceAdaptive( surface0 );
        var tess2 = Tess.rationalSurfaceAdaptive( surface1 );

        var resApprox = Intersect.meshes( tess1, tess2 );

        // 2) refine the intersection points so that they lie on both surfaces
        var exactPls = resApprox.map(function(pl){
            return pl.map( function(inter : MeshIntersectionPoint){
                return Intersect.surfaces_at_point_with_estimate( surface0, surface1, inter.uv0, inter.uv1, tol );
            });
        });

        // 3) perform cubic interpolation
        return exactPls.map(function(x){
            return Make.rationalInterpCurve( x.map(function(x){ return x.point; }), 3 );
        });
    }

    //
    // Refine a pair of surface points to a point where the two surfaces intersect
    //
    // **params**
    // + SurfaceData for the first surface
    // + SurfaceData for the second
    // + the UV for the point on the first surface
    // + the UV for the point on the second surface
    // + a tolerance value to terminate the refinement procedure
    //
    // **returns**
    // + a SurfaceSurfaceIntersectionPoint object
    //
    public static function surfaces_at_point_with_estimate(surface0 : SurfaceData,
                                                           surface1 : SurfaceData,
                                                           uv1 : UV,
                                                           uv2 : UV,
                                                           tol : Float ) : SurfaceSurfaceIntersectionPoint {

        var pds, p, pn, pu, pv, pd, qds, q, qn, qu, qv, qd, dist;
        var maxits = 10;
        var its = 0;

        do {
            // 1) eval normals, pts on respective surfaces (p, q, pn, qn)
            pds = Eval.rationalSurfaceDerivatives( surface0, 1, uv1[0], uv1[1] );
            p = pds[0][0];
            pu = pds[1][0];
            pv = pds[0][1];
            pn = Vec.normalized( Vec.cross( pu, pv ) );
            pd = Vec.dot( pn, p );

            qds = Eval.rationalSurfaceDerivatives( surface0, 1, uv2[0], uv2[1] );
            q = qds[0][0];
            qu = qds[1][0];
            qv = qds[0][1];
            qn = Vec.normalized( Vec.cross( qu, qv ) );
            qd = Vec.dot( qn, q );

            // if tolerance is met, exit loop
            dist = Vec.norm( Vec.sub(p, q) );

            if (dist < tol) {
                break;
            }

            // 2) construct plane perp to both that passes through p (fn)
            var fn = Vec.normalized( Vec.cross( pn, qn ) );
            var fd = Vec.dot( fn, p );

            // 3) x = intersection of all 3 planes
            var x = Intersect.threePlanes( pn, pd, qn, qd, fn, fd );

            if (x == null) throw "panic!";

            // 4) represent the difference vectors (pd = x - p, qd = x - q) in the partial
            // 		derivative vectors of the respective surfaces (pu, pv, qu, qv)

            var pdif = Vec.sub( x, p );
            var qdif = Vec.sub( x, q );

            var rw = Vec.cross( pu, pn );
            var rt = Vec.cross( pv, pn );

            var su = Vec.cross( qu, qn );
            var sv = Vec.cross( qv, qn );

            var dw = Vec.dot( rt, pdif ) / Vec.dot( rt, pu );
            var dt = Vec.dot( rw, pdif ) / Vec.dot( rw, pv );

            var du = Vec.dot( sv, qdif ) / Vec.dot( sv, qu );
            var dv = Vec.dot( su, qdif ) / Vec.dot( su, qv );

            uv1 = Vec.add( [dw, dt], uv1 );
            uv2 = Vec.add( [du, dv], uv2 );

            // repeat
            its++;

        } while( its < maxits );

        return new SurfaceSurfaceIntersectionPoint(uv1, uv2, p, dist);
    }

    //
    // Intersect two meshes, yielding a list of polylines
    //
    // **params**
    // + MeshData for the first mesh
    // + MeshData for the latter
    //
    // **returns**
    // + array of array of MeshIntersectionPoints
    //

    public static function meshes( mesh0 : MeshData, mesh1 : MeshData ) : Array<Array<MeshIntersectionPoint>> {

        // bounding box intersection to get all of the face pairs
        var bbints = Intersect.bounding_box_trees(
            new LazyMeshBoundingBoxTree( mesh0 ),
            new LazyMeshBoundingBoxTree( mesh1 ), 0 );

        // get the segments of the intersection crv with uvs
        var segments = bbints.map(function(ids : Pair<Int, Int>){
            return Intersect.triangles( mesh0, ids.item0, mesh1, ids.item1 );
        })
        .filter(function(x){
            return x != null;
        })
        .filter(function(x){
            return Vec.distSquared( x.min.point, x.max.point ) > Constants.EPSILON;
        })
        .unique(function(a, b){

            // TODO: this is too expensive and this only occurs when the intersection
            // 		line is on an edge.  we should mark these to avoid doing all of
            //		these computations

            var s1 = Vec.sub( a.min.uv0, b.min.uv0 );
            var d1 = Vec.dot( s1, s1 );

            var s2 = Vec.sub( a.max.uv0, b.max.uv0 );
            var d2 = Vec.dot( s2, s2 );

            var s3 = Vec.sub( a.min.uv0, b.max.uv0 );
            var d3 = Vec.dot( s3, s3 );

            var s4 = Vec.sub( a.max.uv0, b.min.uv0 );
            var d4 = Vec.dot( s4, s4 );

            return ( d1 < Constants.EPSILON && d2 < Constants.EPSILON ) ||
                ( d3 < Constants.EPSILON && d4 < Constants.EPSILON );

        });

        if (segments.length == 0) return [];

        return makeMeshIntersectionPolylines( segments );

    }

    //
    // Given a list of unstructured mesh intersection segments, reconstruct into polylines
    //
    // **params**
    // + unstructured collection of segments
    //
    // **returns**
    // + array of array of MeshIntersectionPoint
    //

    public static function makeMeshIntersectionPolylines( segments : Array<Interval<MeshIntersectionPoint>> ) : Array<Array<MeshIntersectionPoint>> {

        // debug (return all segments)
        // return segments;

        // we need to tag the segment ends
        for (s in segments){
            s.max.opp = s.min;
            s.min.opp = s.max;
        }

        // construct a tree for fast lookup
        var tree = kdTreeFromSegments( segments );

        // flatten everything, we no longer need the segments
        var ends : Array<MeshIntersectionPoint> = [];

        for (seg in segments){
            ends.push(seg.min);
            ends.push(seg.max);
        }

        // step 1: assigning the vertices to the segment ends
        for (segEnd in ends){
            if (segEnd.adj != null) continue;

            var adjEnd = lookupAdjacentSegment( segEnd, tree, segments.length );

            if (adjEnd != null && adjEnd.adj == null){
                segEnd.adj = adjEnd;
                adjEnd.adj = segEnd;
            }
        }

        // step 2: traversing the topology to construct the pls
        var freeEnds = ends.filter(function(x){
            return x.adj == null;
        });

        // if you cant find one, youve got a loop (or multiple), we run through all
        if (freeEnds.length == 0) {
            freeEnds = ends;
        }

        var pls = [];

        for (end in freeEnds){

            if (end.visited) continue;

            // traverse to end
            var pl = [];
            var curEnd = end;

            while (curEnd != null) {

                // debug
                if (curEnd.visited) throw 'Segment end encountered twice!';

                // technically we consume both ends of the segment
                curEnd.visited = true;
                curEnd.opp.visited = true;

                pl.push(curEnd);

                curEnd = curEnd.opp.adj;

                // loop condition
                if (curEnd == end) break;
            }

            if (pl.length > 0) {
                pl.push( pl[pl.length-1].opp );
                pls.push( pl );
            }
        }

        return pls;
    }

    //
    // Form a KD-tree from a collection of mesh intersection segments
    //
    // **params**
    // + unstructured collection of segments
    //
    // **returns**
    // + array of array of MeshIntersectionPoint
    //

    private static function kdTreeFromSegments( segments: Array<Interval<MeshIntersectionPoint>> ) : KdTree<MeshIntersectionPoint> {

        var treePoints = [];

        // for each segment, transform into two elements, each keyed by pt1 and pt2
        for (seg in segments){
            treePoints.push(new KdPoint(seg.min.point, seg.min ));
            treePoints.push(new KdPoint(seg.max.point, seg.max ));
        }

        // make our tree
        return new KdTree(treePoints, Vec.distSquared);
    }

    //
    // Given a segment end
    //
    // **params**
    // + unstructured collection of segments
    //
    // **returns**
    // + array of array of MeshIntersectionPoint
    //
    public static function lookupAdjacentSegment( segEnd: MeshIntersectionPoint, tree : KdTree<MeshIntersectionPoint>, numSegments : Int ) {

        var numResults : Int = numSegments != null ? (numSegments < 3 ? 3 : numSegments) : 3;

        // we look up 3 elements because we need to find the unique adj ele
        // we expect one result to be self, one to be neighbor and no more
        var adj = tree.nearest(segEnd.point, numResults, Constants.EPSILON)
        .filter(function(r){
            return segEnd != r.item0.obj;
        })
        .map(function(r){ return r.item0.obj; });

        // if its not unique (i.e. were at a branching point) we dont return it
        return (adj.length == 1) ? adj[0] : null;

    }

    //
    // Get the intersection of a NURBS curve and a NURBS surface without an estimate
    //
    // **params**
    // + CurveData
    // + SurfaceData
    // + tolerance for the curve intersection
    //
    // **returns**
    // + array of CurveSurfaceIntersection objects
    //

    public static function curveAndSurface( curve : CurveData,
                                              surface : SurfaceData,
                                              tol : Float = 1e-3 )  {

        var ints = Intersect.bounding_box_trees(
            new LazyCurveBoundingBoxTree( curve ),
            new LazySurfaceBoundingBoxTree( surface ), 0 );

        return ints.map(function( inter ){

            var crvSeg = inter.item0;
            var srfPart = inter.item1;

            // get the middle param of the curve
            var min = crvSeg.knots.first();
            var max = crvSeg.knots.last();

            var u = (min + max) / 2.0;

            // get the middle param of the surface
            var minu = srfPart.knotsU.first();
            var maxu = srfPart.knotsU.last();

            var minv = srfPart.knotsV.first();
            var maxv = srfPart.knotsV.last();

            var uv = [ (minu + maxu) / 2.0, (minv + maxv) / 2.0 ];

            return Intersect.curveAndSurfaceWithEstimate( crvSeg, srfPart, [u].concat(uv), tol );

        });
    }

    //
    // Refine an intersection pair for a surface and curve given an initial guess.  This is an unconstrained minimization,
    // so the caller is responsible for providing a very good initial guess.
    //
    // **params**
    // + CurveData
    // + SurfaceData
    // + array of initial parameter values [ u_crv, u_srf, v_srf ]
    //
    // **returns**
    // + a CurveSurfaceIntersection object
    //

    public static function curveAndSurfaceWithEstimate(    curve : CurveData,
                                                               surface : SurfaceData,
                                                               start_params : Array<Float>,
                                                               tol : Float = 1e-3 ) : CurveSurfaceIntersection {

        var objective = function(x) {
            var p1 = Eval.rationalCurvePoint( curve, x[0])
            , p2 = Eval.rationalSurfacePoint( surface, x[1], x[2] )
            , p1_p2 = Vec.sub(p1, p2);

            return Vec.dot(p1_p2, p1_p2);
        }

        var sol_obj = Numeric.uncmin( objective, start_params, tol );
        var final = sol_obj.solution;

        return new CurveSurfaceIntersection( final[0], [ final[1], final[2] ] );
    }

    //
    // Approximate the intersection of a polyline and mesh while maintaining parameter information
    //
    // **params**
    // + PolylineData
    // + MeshData
    //
    // **returns**
    // + an array of PolylineMeshIntersection object
    //

    public static function polyline_and_mesh( polyline : PolylineData,
                                              mesh : MeshData,
                                              tol : Float ) : Array<PolylineMeshIntersection> {

        var res = Intersect.bounding_box_trees(
            new LazyPolylineBoundingBoxTree( polyline ),
            new LazyMeshBoundingBoxTree( mesh ), tol );

        var finalResults = [];

        for (event in res) {

            var polid = event.item0;
            var faceid = event.item1;

            var inter = Intersect.segmentWithTriangle( polyline.points[polid], polyline.points[polid + 1], mesh.points, mesh.faces[ faceid ] );
            if ( inter == null ) continue;

            var pt = inter.point;
            var u = Vec.lerp(inter.p, [ polyline.params[polid] ], [ polyline.params[polid+1] ] )[0];
            var uv = Mesh.triangleUVFromPoint( mesh, faceid,  pt );

            finalResults.push(new PolylineMeshIntersection( pt, u, uv, polid, faceid ));

        }

        return finalResults;
    }

    public static function mesh_bounding_boxes( a : MeshData, b : MeshData, tol : Float ) : Array<Pair<Int,Int>> {
        return Intersect.bounding_box_trees(new LazyMeshBoundingBoxTree(a), new LazyMeshBoundingBoxTree(b), tol );
    }

    //
    // The core algorithm for bounding box tree intersection, supporting both lazy and pre-computed bounding box trees
    // via the IBoundingBoxTree interface
    //
    // **params**
    // + an IBoundingBoxTree object
    // + a second IBoundingBoxTree object
    // + the tolerance for the intersection, used by BoundingBox.intersects
    //
    // **returns**
    // + an array of Pair objects extracted from the yield method of IBoundingBoxTree
    //
    public static function bounding_box_trees<T1, T2>( a : IBoundingBoxTree<T1>, b : IBoundingBoxTree<T2>, tol : Float = 1e-9 )
        : Array<Pair<T1,T2>> {

        if (a.empty() || b.empty()) return [];

        if ( !a.boundingBox().intersects( b.boundingBox(), tol ) ) return [];

        if (a.indivisible(tol) && b.indivisible(tol) ) return [ new Pair(a.yield(), b.yield()) ];

        var asplit = a.split()
            , bsplit = b.split();

        return     Intersect.bounding_box_trees( asplit.item0, bsplit.item0, tol )
            .concat( Intersect.bounding_box_trees( asplit.item0, bsplit.item1, tol  ) )
            .concat( Intersect.bounding_box_trees( asplit.item1, bsplit.item0, tol  ) )
            .concat( Intersect.bounding_box_trees( asplit.item1, bsplit.item1, tol  ) );
    }

    //
    // Approximate the intersection of two NURBS curves
    //
    // **params**
    // + CurveData object representing the first NURBS curve
    // + CurveData object representing the second NURBS curve
    // + tolerance for the intersection
    //
    // **returns**
    // + the intersections
    //

    public static function curves( curve1 : CurveData, curve2 : CurveData, tolerance : Float ) : Array<CurveCurveIntersection> {

        var ints = Intersect.bounding_box_trees(
            new LazyCurveBoundingBoxTree( curve1 ),
            new LazyCurveBoundingBoxTree( curve2 ), 0 );

        return ints.map(function(x : Pair<CurveData, CurveData>) : CurveCurveIntersection {
            return Intersect.curves_with_estimate( curve1, curve2, x.item0.knots.first(), x.item1.knots.first(), tolerance );
        });
    }

    //
    // Refine an intersection pair for two curves given an initial guess.  This is an unconstrained minimization,
    // so the caller is responsible for providing a very good initial guess.
    //
    // **params**
    // + CurveData object representing the first NURBS curve
    // + CurveData object representing the second NURBS curve
    // + guess for first parameter
    // + guess for second parameter
    // + tolerance for the intersection
    //
    // **returns**
    // + array of CurveCurveIntersection objects
    //

    private static function curves_with_estimate( curve0 : CurveData,
                                                  curve1 : CurveData,
                                                  u0 : Float,
                                                  u1 : Float,
                                                  tolerance : Float ) : CurveCurveIntersection
    {
        var objective = function( x : Vector ) : Float {
            var p1 = Eval.rationalCurvePoint(curve0, x[0])
            , p2 = Eval.rationalCurvePoint(curve1, x[1])
            , p1_p2 = Vec.sub(p1, p2);

            return Vec.dot(p1_p2, p1_p2);
        }

        var sol_obj = Numeric.uncmin( objective, [u0, u1], tolerance );

        var u1 = sol_obj.solution[0]
            , u2 = sol_obj.solution[1];

        var p1 = Eval.rationalCurvePoint(curve0, u1)
        , p2 = Eval.rationalCurvePoint(curve1, u2 );

        return new CurveCurveIntersection(p1, p2, u1, u2);
    }

    //
    // Intersect two triangles
    //
    // **params**
    // + array of length 3 arrays of numbers representing the points of mesh1
    // + array of length 3 arrays of number representing the triangles of mesh1
    // + array of length 3 arrays of numbers representing the points of mesh2
    // + array of length 3 arrays of number representing the triangles of mesh2
    //
    // **returns**
    // + a point represented by an array of length (dim)
    //

    public static function triangles( mesh0 : MeshData, faceIndex0 : Int, mesh1 : MeshData, faceIndex1 : Int ) : Interval<MeshIntersectionPoint>{

        var tri0 = mesh0.faces[faceIndex0];
        var tri1 = mesh1.faces[faceIndex1];

        // 0) get the plane rep of the two triangles
        var n0 = Mesh.getTriangleNorm( mesh0.points, tri0 );
        var n1 = Mesh.getTriangleNorm( mesh1.points, tri1 );
        var o0 = mesh0.points[ tri0[0] ];
        var o1 = mesh1.points[ tri1[0] ];

        // 1) intersect with planes to yield ray of intersection
        var ray = Intersect.planes(o0, n0, o1, n1);
        if (ray == null) return null;

        // 2) clip the ray within tri0
        var clip1 = clipRayInCoplanarTriangle( ray, mesh0, faceIndex0 );
        if (clip1 == null) return null;

        // 3) clip the ray within tri1
        var clip2 = clipRayInCoplanarTriangle( ray, mesh1, faceIndex1 );
        if (clip2 == null) return null;

        // 4) find the interval that overlaps
        var merged = mergeTriangleClipIntervals(clip1, clip2, mesh0, faceIndex0, mesh1, faceIndex1 );
        if (merged == null) return null;

        return return new Interval(
            new MeshIntersectionPoint(merged.min.uv0, merged.min.uv1, merged.min.point, faceIndex0, faceIndex1 ),
            new MeshIntersectionPoint(merged.max.uv0, merged.max.uv1, merged.max.point, faceIndex0, faceIndex1 ));

    }

    public static function clipRayInCoplanarTriangle(ray : Ray, mesh : MeshData, faceIndex : Int ) : Interval<CurveTriPoint> {

        // 0) construct rays for each edge of the triangle
        var tri = mesh.faces[faceIndex]
        , o = [ mesh.points[ tri[0] ], mesh.points[ tri[1] ], mesh.points[ tri[2] ] ]
        , uvs = [ mesh.uvs[ tri[0] ], mesh.uvs[ tri[1] ], mesh.uvs[ tri[2] ] ]
        , uvd = [ Vec.sub(uvs[1], uvs[0]), Vec.sub(uvs[2], uvs[1]), Vec.sub(uvs[0], uvs[2]) ]
        , s = [ Vec.sub( o[1], o[0] ), Vec.sub( o[2], o[1] ), Vec.sub( o[0], o[2] ) ]
        , d = s.map( Vec.normalized )
        , l = s.map( Vec.norm );

        // 1) for each tri ray, if intersects and in segment interval, store minU, maxU
        var minU : CurveTriPoint = null;
        var maxU : CurveTriPoint = null;

        // need to clip in order to maximize the width of the intervals
        for (i in 0...3){
            var o0 = o[i];
            var d0 = d[i];

            var res = Intersect.rays( o0, d0, ray.origin, ray.dir );

            if (res == null) {
                continue;
            }

            var useg = res.u0;
            var uray = res.u1;

            // if outside of triangle edge interval, discard
            if (useg < -Constants.EPSILON || useg > l[i] + Constants.EPSILON) continue;

            // if inside interval
            if (minU == null || uray < minU.u){
                minU = new CurveTriPoint( uray, Vec.onRay( ray.origin, ray.dir, uray ), Vec.onRay( uvs[i], uvd[i], useg / l[i]));
            }

            if (maxU == null || uray > maxU.u){
                maxU = new CurveTriPoint( uray, Vec.onRay( ray.origin, ray.dir, uray ), Vec.onRay( uvs[i], uvd[i], useg / l[i]));
            }
        }

        if (maxU == null || minU == null) {
            return null;
        }

        // 3) otherwise, return minU maxU along with uv info
        return new Interval<CurveTriPoint>(minU, maxU);

    }

    public static function mergeTriangleClipIntervals(clip1 : Interval<CurveTriPoint>, clip2 : Interval<CurveTriPoint>,
                                                    mesh1 : MeshData, faceIndex1 : Int, mesh2 : MeshData, faceIndex2 : Int ) : Interval<MeshIntersectionPoint> {

        // if the intervals dont overlap, fail
        if ( clip2.min.u > clip1.max.u + Constants.EPSILON
            || clip1.min.u > clip2.max.u + Constants.EPSILON) {
            return null;
        }

        // are these assigned properly?
        var min = (clip1.min.u > clip2.min.u) ? new Pair<CurveTriPoint, Int>(clip1.min, 0) : new Pair<CurveTriPoint, Int>(clip2.min, 1);
        var max = (clip1.max.u < clip2.max.u) ? new Pair<CurveTriPoint, Int>(clip1.max, 0) : new Pair<CurveTriPoint, Int>(clip2.max, 1);

        var res = new Interval(
            new MeshIntersectionPoint(null, null, min.item0.point, faceIndex1, faceIndex2),
            new MeshIntersectionPoint(null, null, max.item0.point, faceIndex1, faceIndex2));

        if (min.item1 == 0){
            res.min.uv0 = min.item0.uv;
            res.min.uv1 = Mesh.triangleUVFromPoint( mesh2, faceIndex2, min.item0.point );
        } else {
            res.min.uv0 = Mesh.triangleUVFromPoint( mesh1, faceIndex1, min.item0.point );
            res.min.uv1 = min.item0.uv;
        }

        if (max.item1 == 0){
            res.max.uv0 = max.item0.uv;
            res.max.uv1 = Mesh.triangleUVFromPoint( mesh2, faceIndex2, max.item0.point );
        } else {
            res.max.uv0 = Mesh.triangleUVFromPoint( mesh1, faceIndex1, max.item0.point );
            res.max.uv1 = max.item0.uv;
        }

        return res;
    }

    //
    // Intersect two planes, yielding a Ray
    //
    // **params**
    // + point in plane 0
    // + normal to plane 0
    // + point in plane 1
    // + normal to plane 1
    //
    // **returns**
    // + a point represented by an array of length (dim)
    //

    public static function planes(origin0 : Point, normal0 : Vector, origin1 : Point, normal1: Vector) : Ray {

        var d = Vec.cross(normal0, normal1);

        if (Vec.dot(d, d) < Constants.EPSILON) return null;

        // find the largest index of d
        var li = 0;
        var mi = Math.abs( d[0] );
        var m1 = Math.abs( d[1] );
        var m2 = Math.abs( d[2] );

        if ( m1 > mi ){
            li = 1;
            mi = m1;
        }

        if ( m2 > mi ){
            li = 2;
            mi = m2;
        }

        var a1, b1, a2, b2;

        if ( li == 0 ){
            a1 = normal0[1];
            b1 = normal0[2];
            a2 = normal1[1];
            b2 = normal1[2];
        } else if ( li == 1 ){
            a1 = normal0[0];
            b1 = normal0[2];
            a2 = normal1[0];
            b2 = normal1[2];
        } else {
            a1 = normal0[0];
            b1 = normal0[1];
            a2 = normal1[0];
            b2 = normal1[1];
        }

        // n dot X = d
        var d1 = -Vec.dot( origin0, normal0 );
        var d2 = -Vec.dot( origin1, normal1 );

        var den = a1 * b2 - b1 * a2;

        var x = (b1 * d2 - d1 * b2) / den;
        var y = (d1 * a2 - a1 * d2) / den;
        var p;

        if ( li == 0 ){
            p = [0,x,y];
        } else if ( li == 1 ){
            p = [x,0,y];
        } else {
            p = [x,y,0];
        }

        return new Ray(p, Vec.normalized( d ) );

    }

    //
    // Intersect three planes, expects the planes to form a single point of
    // intersection
    //
    // **params**
    // + normal for plane 0
    // + d for plane 0 ( where the plane eq is normal * (x,y,z) = d )
    // + normal for plane 1
    // + d for plane 1 ( where the plane eq is normal * (x,y,z) = d )
    // + normal for plane 2
    // + d for plane 2 ( where the plane eq is normal * (x,y,z) = d )
    //
    // **returns**
    // + the point representing the intersection
    //
    public static function threePlanes(n0 : Point, d0 : Float, n1 : Point, d1 : Float, n2 : Point, d2 : Float) : Point {

        var u = Vec.cross( n1, n2 );
        var den = Vec.dot( n0, u );

        if (Math.abs(den) < Constants.EPSILON) return null;

        var diff = Vec.sub( Vec.mul( d2, n1 ), Vec.mul( d1, n2 ) );
        var num = Vec.add( Vec.mul( d0, u ), Vec.cross( n0, diff));

        return Vec.mul( 1 / den, num );

    }

    //
    // Intersect two polyline curves, keeping track of parameterization on each
    //
    // **params**
    // + PolylineData for first polyline
    // + PolylineData for second polyline
    // + tolerance for the intersection
    //
    // **returns**
    // + array of parameter pairs representing the intersection of the two parameteric polylines
    //

    public static function polylines( polyline0 : PolylineData, polyline1 : PolylineData, tol : Float )
        : Array<CurveCurveIntersection> {

        var res = Intersect.bounding_box_trees(
            new LazyPolylineBoundingBoxTree( polyline0 ),
            new LazyPolylineBoundingBoxTree( polyline1 ), tol );

        var finalResults = [];

        for (event in res) {
            var polid0 = event.item0;
            var polid1 = event.item1;

            var inter = Intersect.segments(polyline0.points[polid0],polyline0.points[polid0+1],
            polyline1.points[polid1],polyline1.points[polid1+1], tol);

            if ( inter == null ) continue;

            // remap to full parametric domain of polyline
            inter.u0 = Vec.lerp(inter.u0, [ polyline0.params[polid0] ], [ polyline0.params[polid0+1] ] )[0];
            inter.u1 = Vec.lerp(inter.u1, [ polyline1.params[polid1] ], [ polyline1.params[polid1+1] ] )[0];

            finalResults.push(inter);
        }

        return finalResults;
    }

    //
    // Find the closest parameter on two rays, see http://geomalgorithms.com/a07-_distance.html
    //
    // **params**
    // + first end of the first segment
    // + second end of the first segment
    // + first end of the second segment
    // + second end of the second segment
    // + tolerance for the intersection
    //
    // **returns**
    // + a CurveCurveIntersection object
    //

    public static function segments( a0 : Point, a1 : Point, b0 : Point, b1 : Point, tol : Float ) : CurveCurveIntersection {

        var a1ma0 = Vec.sub(a1, a0),
            aN = Math.sqrt( Vec.dot(a1ma0, a1ma0) ),
            a = Vec.mul( 1/ aN, a1ma0 ),
            b1mb0 = Vec.sub(b1, b0),
            bN = Math.sqrt( Vec.dot(b1mb0, b1mb0) ),
            b = Vec.mul( 1 / bN, b1mb0 ),
            int_params = Intersect.rays(a0, a, b0, b);

        if ( int_params != null ) {

            var u0 = Math.min( Math.max( 0, int_params.u0 / aN ), 1.0),
                u1 = Math.min( Math.max( 0, int_params.u1 / bN ), 1.0),
                point0 = Vec.onRay( a0, a1ma0, u0 ),
                point1 = Vec.onRay( b0, b1mb0, u1 ),
                dist = Vec.distSquared(point0, point1);

            if (  dist < tol*tol ) {
                return new CurveCurveIntersection( point0, point1, u0, u1 );
            }
        }

        return null;
    }

    //
    // Find the closest parameter on two rays, see http://geomalgorithms.com/a07-_distance.html
    //
    // **params**
    // + origin for ray 1
    // + direction of ray 1, assumed normalized
    // + origin for ray 1
    // + direction of ray 1, assumed normalized
    //
    // **returns**
    // + a CurveCurveIntersection object
    //

    public static function rays( a0 : Point, a : Point, b0 : Point, b : Point ) : CurveCurveIntersection {

        var dab = Vec.dot( a, b ),
        dab0 = Vec.dot( a, b0 ),
        daa0 = Vec.dot( a, a0 ),
        dbb0 = Vec.dot( b, b0 ),
        dba0 = Vec.dot( b, a0 ),
        daa = Vec.dot( a, a ),
        dbb = Vec.dot( b, b ),
        div = daa*dbb - dab*dab;

        // parallel case
        if ( Math.abs( div ) < Constants.EPSILON ) {
            return null;
        }

        var num = dab * (dab0-daa0) - daa * (dbb0-dba0),
        w = num / div,
        t = (dab0 - daa0 + w * dab)/daa;

        var p0 = Vec.onRay( a0, a, t );
        var p1 = Vec.onRay( b0, b, w );

        return new CurveCurveIntersection( p0, p1, t, w );
    }


    //
    //  Intersect segment with triangle (from http://geomalgorithms.com/a06-_intersect-2.html)
    //
    // **params**
    // + array of length 3 representing first point of the segment
    // + array of length 3 representing second point of the segment
    // + array of length 3 arrays representing the points of the triangle
    // + array of length 3 containing int indices in the array of points, this allows passing a full mesh
    //
    // **returns**
    // + a TriangleSegmentIntersection or null if failed
    //

    public static function segmentWithTriangle( p0 : Point, p1 : Point, points : Array<Point>, tri : Tri ) : TriSegmentIntersection {

        var v0 = points[ tri[0] ]
        , v1 = points[ tri[1] ]
        , v2 = points[ tri[2] ]
        , u = Vec.sub( v1, v0 )
        , v = Vec.sub( v2, v0 )
        , n = Vec.cross( u, v );

        var dir = Vec.sub( p1, p0 )
        , w0 = Vec.sub( p0, v0 )
        , a = -Vec.dot( n, w0 )
        , b = Vec.dot( n, dir );

        // is ray is parallel to triangle plane?
        if ( Math.abs( b ) < Constants.EPSILON ){
            return null;
        }

        var r = a / b;

        // segment goes away from triangle or is beyond segment
        if ( r < 0 || r > 1 ){
            return null;
        }

        // get proposed intersection
        var pt = Vec.add( p0, Vec.mul( r, dir ) );

        // is I inside T?
        var uv = Vec.dot(u,v)
        , uu = Vec.dot(u,u)
        , vv = Vec.dot(v,v)
        , w = Vec.sub( pt, v0 )
        , wu = Vec.dot( w, u )
        , wv = Vec.dot( w, v )
        , denom = uv * uv - uu * vv;

        if (Math.abs(denom) < Constants.EPSILON){
            return null;
        }

        var s = ( uv * wv - vv * wu ) / denom
        , t = ( uv * wu - uu * wv ) / denom;

        if (s > 1.0 + Constants.EPSILON || t > 1.0 + Constants.EPSILON || t < -Constants.EPSILON || s < -Constants.EPSILON || s + t > 1.0 + Constants.EPSILON){
            return null;
        }

        return new TriSegmentIntersection(pt, s, t, r );

    }
    //
    //  Intersect ray/segment with plane (from http://geomalgorithms.com/a06-_intersect-2.html)
    //
    //  If intersecting a ray, the param needs to be between 0 and 1 and the caller is responsible
    //  for making that check
    //
    // **params**
    // + array of length 3 representing first point of the segment
    // + array of length 3 representing second point of the segment
    // + array of length 3 representing an origin point on the plane
    // + array of length 3 representing the normal of the plane
    //
    // **returns**
    // null or an object with a p property representing the param on the segment
    //

    public static function segment_with_plane( p0 : Point, p1 : Point, v0 : Point, n : Point ) {

        var denom = Vec.dot( n, Vec.sub(p0,p1) );

        // parallel case
        if ( Math.abs( denom ) < Constants.EPSILON ) {
            return null;
        }

        var numer = Vec.dot( n, Vec.sub(v0,p0) );

        return { p: numer / denom };

    }

}
