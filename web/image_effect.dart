import "dart:html";
import "dart:async";
import "dart:convert";
import "dart:typed_data";
import "dart:web_gl" as GL;
import "dart:math" as Math;

import "package:vector_math/vector_math.dart";

class Canvas {
  static const int CANVAS_WIDTH = 512;
  static const int CANVAS_HEIGHT = 512;

  CanvasElement _canvas;
  CanvasElement _video_canvas;

  CanvasRenderingContext2D _video_canvas_context;

  GL.RenderingContext _gl;
  GL.Program _program;

  GL.Buffer _vbo_position;
  GL.Buffer _vbo_coord;
  GL.Buffer _ibo_indices;
  int _indices_length;

  GL.UniformLocation _u_mvp_matrix;
  GL.UniformLocation _u_texture;

  GL.Texture _video_texture;

  Vector3 _look_from = new Vector3(0.0, 0.0, 35.0);
  Quaternion _quaternion = new Quaternion.identity();

  int _a_position;
  int _a_texture_coord;

  VideoElement _video;

  static const String VS =
  """
  attribute vec3 position;
  attribute vec2 texture_coord;

  uniform mat4 mvp_matrix;

  varying vec2 v_texture_coord;

  void main(void){
      v_texture_coord = texture_coord;
      gl_Position   = mvp_matrix * vec4(position, 1.0);
  }
  """;

  static const String FS =
  """
  precision mediump float;

  uniform sampler2D texture;
  uniform sampler2D texture_3d;
  varying vec2 v_texture_coord;

  void main(void){
    float h = 1.0 / 512.0;
    float p = 1.0 / 256.0;
    float q = 1.0 / 256.0;

    vec4 src = texture2D(texture, v_texture_coord);
    float y = src.g * 15.0 * p + h;

    float z = src.b * 15.0;
    float z0 = floor(z);
    float z1 = ceil(z);

    float x0 = z0 * 16.0 * p + src.r * 15.0 * p + h;
    float x1 = z1 * 16.0 * p + src.r * 15.0 * p + h;
    vec4 c0 = texture2D(texture_3d, vec2(x0, y));
    vec4 c1 = texture2D(texture_3d, vec2(x1, y));

    float blend = clamp(z1 - z0, 0.0, 1.0);

    gl_FragColor  = (c1 - c0) * blend + c0;
  }
  """;

  static const String MOVIE_URI = "movie.mp4";
  static const int MOVIE_WIDTH = 854;
  static const int MOVIE_HEIGHT = 480;

  CanvasElement _createTextureLink(String anchor_selector, String canvas_selector, f(Vector3)) {
    var canvas_element = document.querySelector(canvas_selector) as CanvasElement;
    this._drawTexture3D(canvas_element, f);
    document.querySelector(anchor_selector).onClick.listen((MouseEvent event){
      event.preventDefault();
      this._setTexture3D(canvas_element);
    });
    return canvas_element;
  }

  Canvas(String selector) {

    CanvasElement canvas = querySelector(selector);
    this._initWebGL(canvas);
    this._initShader();
    this._initVideoTexture();

    this._initTexture3D();

    var default_canvas = this._createTextureLink("#default_link", "#default", (Vector3 p){
      return new Vector4(p.r, p.g, p.b, 1.0);
    });

    this._createTextureLink("#sin_link", "#sin", (Vector3 p){
      return new Vector4(Math.sin(p.r), Math.sin(p.g), Math.sin(p.b), 1.0);
    });

    this._createTextureLink("#bgr_link", "#bgr", (Vector3 p){
      return new Vector4(p.b, p.g, p.r, 1.0);
    });

    this._createTextureLink("#high_link", "#high", (Vector3 p){
      return new Vector4(p.r * 0.5 + 0.5, p.g * 0.5 + 0.5, p.b * 0.5 + 0.5, 1.0);
    });

    this._createTextureLink("#low_link", "#low", (Vector3 p){
      return new Vector4(p.r * 0.5, p.g * 0.5, p.b * 0.5, 1.0);
    });

    this._createTextureLink("#negpos_link", "#negpos", (Vector3 p){
      return new Vector4(1.0 - p.r, 1.0 - p.g, 1.0 - p.b, 1.0);
    });

    this._createTextureLink("#binary_link", "#binary", (Vector3 rgb){
      num s = Math.max(Math.max(rgb.r, rgb.g), rgb.b);
      if(s < 0.8) {
        s = 0.0;
      } else {
        s = 1.0;
      }
      return new Vector4(s, s, s, 1.0);
    });

    this._createTextureLink("#gray_link", "#gray", (Vector3 rgb){
      num s = Math.max(Math.max(rgb.r, rgb.g), rgb.b);
      return new Vector4(s, s, s, 1.0);
    });

    this._createTextureLink("#red_link", "#red", (Vector3 p){
      return new Vector4(p.r, 0.0, 0.0, 1.0);
    });

    this._createTextureLink("#green_link", "#green", (Vector3 p){
      return new Vector4(0.0, p.g, 0.0, 1.0);
    });

    this._createTextureLink("#blue_link", "#blue", (Vector3 p){
      return new Vector4(0.0, 0.0, p.b, 1.0);
    });

    this._setTexture3D(default_canvas);

    //this,_initTrackBall();

    this._gl.useProgram(this._program);
  }

  CanvasElement _texture_3d_canvas;
  CanvasRenderingContext2D _texture_3d_ctx;
  ImageData _texture_3d_image_data;
  GL.Texture _texture_3d;
  GL.UniformLocation _u_texture_3d;

  void _initTexture3D() {
    var gl = this._gl;

    this._texture_3d = gl.createTexture();
    gl.bindTexture(GL.TEXTURE_2D, this._texture_3d);
    gl.pixelStorei(GL.UNPACK_FLIP_Y_WEBGL, 1);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.LINEAR);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.LINEAR);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE);
    gl.bindTexture(GL.TEXTURE_2D, null);

    this._texture_3d_canvas = new CanvasElement()
      ..width = 256
      ..height = 256
    ;

    this._texture_3d_ctx = this._texture_3d_canvas.getContext("2d");
    this._texture_3d_image_data = this._texture_3d_ctx.getImageData(0, 0, 256, 256);
  }

  void _drawTexture3D(CanvasElement canvas, Vector4 f(Vector3)) {
    var ctx = canvas.getContext("2d") as CanvasRenderingContext2D;
    var im = ctx.getImageData(0, 0, 256, 16);

    for(int y = 0; y < 16; y++) {
      for(int x = 0; x < 256; x++) {
        var color = f(new Vector3(
          (x % 16) / 15,
          1.0 - (y / 15),
          (x ~/ 16) / 15
        ));

        int offset = (y * 256 + x) * 4;
        for(int i = 0; i < 4; i++) {
          im.data[offset + i] = (color.storage[i] * 255.0).toInt();
        }
      }
    }

    ctx.putImageData(im, 0, 0);
  }

  void _setTexture3D(CanvasElement canvas) {
    this._texture_3d_ctx.drawImage(canvas, 0, 16 * 15);

    var gl = this._gl;
    gl.bindTexture(GL.TEXTURE_2D, this._texture_3d);
    gl.texImage2D(GL.TEXTURE_2D, 0, GL.RGBA, GL.RGBA, GL.UNSIGNED_BYTE, this._texture_3d_canvas);
    gl.bindTexture(GL.TEXTURE_2D, null);
  }

  void _initWebGL(CanvasElement canvas) {
    if (canvas == null) {
      throw(new Exception("Could not get element"));
    }
    this._canvas = canvas;

    this._gl = canvas.getContext3d();
    if (this._gl == null) {
      throw(new Exception("Could not initialize WebGL context."));
    }
  }

  void _initShader() {
    var gl = this._gl;
    var vs = gl.createShader(GL.VERTEX_SHADER);
    gl.shaderSource(vs, Canvas.VS);
    gl.compileShader(vs);

    if(!gl.getShaderParameter(vs, GL.COMPILE_STATUS)) {
      throw(new Exception("Could not compile shader\n${gl.getShaderInfoLog(vs)}"));
    }

    var fs = gl.createShader(GL.FRAGMENT_SHADER);
    gl.shaderSource(fs, Canvas.FS);
    gl.compileShader(fs);

    if(!gl.getShaderParameter(fs, GL.COMPILE_STATUS)) {
      throw(new Exception("Could not compile shader\n${gl.getShaderInfoLog(fs)}"));
    }

    var program = gl.createProgram();
    gl.attachShader(program, vs);
    gl.attachShader(program, fs);
    gl.linkProgram(program);

    if(gl.getProgramParameter(program, GL.LINK_STATUS) == null) {
      throw(new Exception("Could not compile shader\n${gl.getProgramInfoLog(program)}"));
    }

    this._u_texture = gl.getUniformLocation(program, "texture");
    this._u_texture_3d = gl.getUniformLocation(program, "texture_3d");
    this._u_mvp_matrix = gl.getUniformLocation(program, "mvp_matrix");

    this._a_position = gl.getAttribLocation(program, "position");
    this._a_texture_coord = gl.getAttribLocation(program, "texture_coord");

    this._program = program;
  }

  void _initVideoTexture() {
    var gl = this._gl;

    this._video_texture = gl.createTexture();
    gl.bindTexture(GL.TEXTURE_2D, this._video_texture);
    gl.pixelStorei(GL.UNPACK_FLIP_Y_WEBGL, 1);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.LINEAR);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.LINEAR);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE);
    gl.bindTexture(GL.TEXTURE_2D, null);

    var video_canvas = new CanvasElement()
      ..width = CANVAS_WIDTH
      ..height = CANVAS_HEIGHT
    ;

    CanvasRenderingContext2D video_canvas_context = video_canvas.getContext("2d");

    this._video_canvas = video_canvas;
    this._video_canvas_context = video_canvas_context;

    this._video = document.querySelector("#video");
//    this._video = new VideoElement()
//      ..width = MOVIE_WIDTH
//      ..height = MOVIE_HEIGHT
//      ..src = MOVIE_URI
//      ..loop = true
//    ;
  }

  void _initTrackBall() {
    Point p0 = null;
    this._canvas.onMouseDown.listen((MouseEvent event){
      event.preventDefault();

      p0 = event.client;
    });

    this._canvas.onMouseMove.listen((MouseEvent event){
      event.preventDefault();

      if(p0 != null) {
        Point p = event.client - p0;
        this._quaternion = (new Quaternion.identity() .. setEuler(p.x * 0.01, p.y * 0.01, 0.0)) * this._quaternion;
        p0 = event.client;
      }
    });

    this._canvas.onMouseUp.listen((MouseEvent event){
      event.preventDefault();

      p0 = null;
    });
  }

  Future<Stream<num>> start() {
    Completer<Stream<num>> completer = new Completer<Stream<num>>();
    Future<Stream<num>> future = completer.future;

    HttpRequest request = new HttpRequest();
    request.onLoad.listen((event){
      var gl = this._gl;
      gl.getExtension("OES_float_linear");
      this._video.play();

      Map mesh = JSON.decode(request.responseText);

      var vbo_position = gl.createBuffer();
      gl.bindBuffer(GL.ARRAY_BUFFER, vbo_position);
      gl.bufferDataTyped(GL.ARRAY_BUFFER, new Float32List.fromList(mesh["positions"] as List<double>), GL.STATIC_DRAW);
      this._vbo_position = vbo_position;

      var vbo_coord = gl.createBuffer();
      gl.bindBuffer(GL.ARRAY_BUFFER, vbo_coord);
      gl.bufferDataTyped(GL.ARRAY_BUFFER, new Float32List.fromList(mesh["coords"] as List<double>), GL.STATIC_DRAW);
      this._vbo_coord = vbo_coord;

      var ibo_indices = gl.createBuffer();
      var indices = mesh["indices"] as List<int>;
      gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, ibo_indices);
      gl.bufferDataTyped(GL.ELEMENT_ARRAY_BUFFER, new Uint16List.fromList(indices), GL.STATIC_DRAW);
      this._ibo_indices = ibo_indices;
      this._indices_length = indices.length;

      StreamController<num> controller = new StreamController<num>.broadcast();
      RequestAnimationFrameCallback render;
      render = (num ms) {
        window.requestAnimationFrame(render);
        controller.add(ms);
      };
      window.requestAnimationFrame(render);

      completer.complete(controller.stream);
    });

    request.open("GET", "plane.json");
    request.send();

    return future;
  }

  void render(num ms) {
    var gl = this._gl;

    Matrix4 projection = new Matrix4.identity();
    num aspect = this._canvas.width / this._canvas.height;
    //setPerspectiveMatrix(projection, Math.PI * 60.0 / 180.0, aspect, 0.1, 1000.0);
    setOrthographicMatrix(projection, -1, 1, -1.0 / aspect, 1.0 / aspect, 0.1, 1000.0);

    Matrix4 view = new Matrix4.identity();
    setViewMatrix(view, this._look_from, new Vector3(0.0, 0.0, 0.0), new Vector3(0.0, 1.0, 0.0));

    Matrix4 model = new Matrix4.identity();
    model.setRotation(this._quaternion.asRotationMatrix());

    Matrix4 mvp = projection * view * model;

    if(this._video_canvas_context != null) {
      var ctx = this._video_canvas_context;
      int height = CANVAS_HEIGHT * MOVIE_HEIGHT ~/ MOVIE_WIDTH;
      int destY = (CANVAS_HEIGHT - height) ~/ 2;
      ctx.drawImageScaled(this._video, 0, destY, CANVAS_WIDTH, height);
    }

    if(this._video_texture != null) {
      gl.bindTexture(GL.TEXTURE_2D, this._video_texture);
      gl.texImage2D(GL.TEXTURE_2D, 0, GL.RGBA, GL.RGBA, GL.UNSIGNED_BYTE, this._video_canvas);
      gl.bindTexture(GL.TEXTURE_2D, null);
    }

    gl.enable(GL.DEPTH_TEST);
    gl.clearColor(0.5, 0.5, 0.5, 1.0);
    gl.clearDepth(1.0);
    gl.viewport(0, 0, this._canvas.width, this._canvas.height);
    gl.clear(GL.COLOR_BUFFER_BIT | GL.DEPTH_BUFFER_BIT);

    if(this._video_texture != null) {
      gl.activeTexture(GL.TEXTURE0);
      gl.bindTexture(GL.TEXTURE_2D, this._video_texture);
    }

    if(this._texture_3d != null) {
      gl.activeTexture(GL.TEXTURE1);
      gl.bindTexture(GL.TEXTURE_2D, this._texture_3d);
    }

    if(this._u_texture != null) {
      gl.uniform1i(this._u_texture, 0);
    }

    if(this._u_texture_3d != null) {
      gl.uniform1i(this._u_texture_3d, 1);
    }

    if(this._u_mvp_matrix != null) {
      gl.uniformMatrix4fv(this._u_mvp_matrix, false, mvp.storage);
    }

    gl.bindBuffer(GL.ARRAY_BUFFER, this._vbo_position);
    gl.enableVertexAttribArray(this._a_position);
    gl.vertexAttribPointer(this._a_position, 3, GL.FLOAT, false, 0, 0);

    gl.bindBuffer(GL.ARRAY_BUFFER, this._vbo_coord);
    gl.enableVertexAttribArray(this._a_texture_coord);
    gl.vertexAttribPointer(this._a_texture_coord, 2, GL.FLOAT, false, 0, 0);

    gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, this._ibo_indices);
    gl.drawElements(GL.TRIANGLES, this._indices_length, GL.UNSIGNED_SHORT, 0);
  }
}

void main()
{
  var canvas = new Canvas("#canvas");
  canvas.start()
  .then((Stream<num> stream){
    stream.listen((num ms){
      canvas.render(ms);
    });
  });
}
