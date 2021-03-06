package verb.core.types;

import verb.core.types.NurbsCurveData.Point;
import verb.core.types.MeshData.UV;

@:expose("core.CurveSurfaceIntersection")
class CurveSurfaceIntersection {

    public var u : Float;
    public var uv : UV;
    public var curvePoint : Point;
    public var surfacePoint : Point;

    public function new( u, uv, curvePoint, surfacePoint ){
        this.u = u;
        this.uv = uv;
        this.curvePoint = curvePoint;
        this.surfacePoint = surfacePoint;
    }
}
