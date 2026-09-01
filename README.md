# x3d-swift

A component-based game engine for Apple platforms, built to learn how engines
fit together. The `XEngine` package splits into three libraries: `XEngineCore`
holds the scene graph, components, animation and math; `XEngineMetal` renders a
scene with Metal and exposes a SwiftUI view; `XEngineLoader` imports OBJ files.

## Install

Add the package to a `Package.swift`:

```swift
.package(url: "https://github.com/afrigon/x3d-swift.git", branch: "main")
```

```swift
.target(name: "App", dependencies: ["XEngineCore", "XEngineMetal"])
```

## Scenes

A scene is a tree of `GameObject`s, each carrying components. `Camera`,
`MeshRenderer`, `Light`, `Script` and `Animator` are components, as is anything
conforming to `GameComponent`.

```swift
let scene = GameScene()

let camera = GameObject(name: "Camera", transform: .init(0, 1, -5))
camera.addComponent(component: Camera())
scene.objects.append(camera)

let cube = GameObject(name: "Cube")
cube.addComponent(component: MeshRenderer(mesh: "cube", material: "red"))
cube.addComponent(component: Script { object, input, delta in
    object.transform.position.y += delta
})
scene.objects.append(cube)

let sun = GameObject(name: "Sun")
sun.addComponent(component: Light.directional(color: .white, intensity: 1))
scene.objects.append(sun)
```

## Rendering

`MetalDriver` drives the update and render loop, and `MetalView` puts it on
screen from SwiftUI. Meshes, materials and textures are registered by name in
the driver's resource repository; `Mesh.cube`, `Mesh.plane` and `Mesh.sphere()`
are built-in prefabs, and a material picks its shader through `MaterialOptions`
— `.unlitColor`, `.normals` or `.blinnPhong`.

```swift
let driver = MetalDriver(scene: scene)!

driver.resourceRepository.registerMesh("cube", mesh: .cube)
driver.resourceRepository.registerMaterial(
    "red",
    material: Material(.blinnPhong(.init(albedoColor: .red)))
)

MetalView(driver: driver)
```

Each camera carries its own post-processing chain, added with
`addPostProcessing(_:)`: `.fxaa()`, `.fog(_:)`, `.ssao` and `.inverted`.

Scripts read the keyboard and mouse through `Input` — `isHeld(key:)`,
`isPressed(key:)`, `cursorDelta`, `scrollDelta` — fed by the view on macOS.
`ObjectFileLoader.load(_:material:repository:)` turns an OBJ file into a
`GameObject` hierarchy with a `MeshRenderer` per object.

## Development

```sh
mise run build
mise run test
mise run lint
mise run format
```

`mise install` fetches the Swift toolchain, swiftlint and swiftformat at the
versions the package is checked against.
