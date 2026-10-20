const faceColor = `
  #include <map_fragment>
  #ifdef USE_MAP
    float nose = 1.0 - smoothstep(0.45, 1.0,
      length((vMapUv - vec2(0.008, 0.577)) / vec2(0.012, 0.026)));
    vec3 nearbySkin = texture2D(map, vec2(0.04, vMapUv.y)).rgb * diffuse;
    diffuseColor.rgb = mix(diffuseColor.rgb, nearbySkin, nose * 0.83);

    float lips = (1.0 - smoothstep(0.065, 0.078, vMapUv.x))
      * smoothstep(0.644, 0.652, vMapUv.y)
      * (1.0 - smoothstep(0.681, 0.689, vMapUv.y));
    float lipHighlight = smoothstep(0.65, 0.88, min(diffuseColor.r, min(diffuseColor.g, diffuseColor.b)));
    vec3 lipSkin = texture2D(map, vec2(0.09, vMapUv.y)).rgb * diffuse;
    diffuseColor.rgb = mix(diffuseColor.rgb, lipSkin, lips * lipHighlight * 0.7);
  #endif
`;

const eyeColor = `
  #include <map_fragment>
  #ifdef USE_MAP
    float iris = smoothstep(0.759, 0.765, vMapUv.x)
      * (1.0 - smoothstep(0.993, 0.999, vMapUv.x))
      * smoothstep(0.003, 0.009, vMapUv.y)
      * (1.0 - smoothstep(0.350, 0.356, vMapUv.y));
    float irisValue = smoothstep(0.012, 0.93, dot(diffuseColor.rgb, vec3(0.2126, 0.7152, 0.0722)));
    float whiteHighlight = smoothstep(0.62, 0.95, min(diffuseColor.r, min(diffuseColor.g, diffuseColor.b)));
    vec3 cyan = mix(irisValue * vec3(0.14, 0.72, 1.12), vec3(irisValue), whiteHighlight);
    diffuseColor.rgb = mix(diffuseColor.rgb, cyan, iris);

    float eyeWhite = smoothstep(0.126, 0.131, vMapUv.x)
      * (1.0 - smoothstep(0.249, 0.254, vMapUv.x))
      * smoothstep(0.352, 0.358, vMapUv.y)
      * (1.0 - smoothstep(0.463, 0.469, vMapUv.y));
    float whiteValue = dot(diffuseColor.rgb, vec3(0.2126, 0.7152, 0.0722));
    diffuseColor.rgb = mix(diffuseColor.rgb, vec3(whiteValue), eyeWhite * 0.45);
  #endif
`;

export function applyFaceMaterials(model) {
  for (const material of model.material) {
    if (material.name === 'face00') {
      material.matcap = null;
      material.fragmentShader = material.fragmentShader.replace('#include <map_fragment>', faceColor);
    } else if (material.name === 'face01') {
      material.fragmentShader = material.fragmentShader.replace('#include <map_fragment>', eyeColor);
    } else {
      continue;
    }
    material.needsUpdate = true;
  }
}
