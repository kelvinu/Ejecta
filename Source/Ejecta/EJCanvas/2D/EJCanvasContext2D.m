#import "EJCanvasContext2D.h"
#import "EJFont.h"
#import "EJApp.h"

@implementation EJCanvasContext2D

EJVertex EJCanvasVertexBuffer[EJ_CANVAS_VERTEX_BUFFER_SIZE];

static const struct { GLenum source; GLenum destination; } EJCompositeOperationFuncs[] = {
	[kEJCompositeOperationSourceOver] = {GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA},
	[kEJCompositeOperationLighter] = {GL_SRC_ALPHA, GL_ONE},
	[kEJCompositeOperationDarker] = {GL_DST_COLOR, GL_ONE_MINUS_SRC_ALPHA},
	[kEJCompositeOperationDestinationOut] = {GL_ZERO, GL_ONE_MINUS_SRC_ALPHA},
	[kEJCompositeOperationDestinationOver] = {GL_ONE_MINUS_DST_ALPHA, GL_ONE},
	[kEJCompositeOperationSourceAtop] = {GL_DST_ALPHA, GL_ONE_MINUS_SRC_ALPHA},
	[kEJCompositeOperationXOR] = {GL_ONE_MINUS_DST_ALPHA, GL_ONE_MINUS_SRC_ALPHA}
};


@synthesize state;
@synthesize backingStoreRatio;
@synthesize useRetinaResolution;
@synthesize imageSmoothingEnabled;

- (id)initWithWidth:(short)widthp height:(short)heightp {
	if( self = [super init] ) {
		glContext = [EJApp instance].glContext2D;
	
		memset(stateStack, 0, sizeof(stateStack));
		stateIndex = 0;
		state = &stateStack[stateIndex];
		state->globalAlpha = 1;
		state->globalCompositeOperation = kEJCompositeOperationSourceOver;
		state->transform = CGAffineTransformIdentity;
		state->lineWidth = 1;
		state->lineCap = kEJLineCapButt;
		state->lineJoin = kEJLineJoinMiter;
		state->miterLimit = 10;
		state->textBaseline = kEJTextBaselineAlphabetic;
		state->textAlign = kEJTextAlignStart;
		state->font = [[UIFont fontWithName:@"Helvetica" size:10] retain];
		state->clipPath = nil;
		
		bufferWidth = width = widthp;
		bufferHeight = height = heightp;
		
		vertexScale = EJVector2Make(2.0f/width, 2.0f/height);
		vertexTranslate = EJVector2Make(-1.0f, -1.0f);
		
		path = [[EJPath alloc] init];
		backingStoreRatio = 1;
		
		fontCache = [[NSCache alloc] init];
		fontCache.countLimit = 8;
		
		imageSmoothingEnabled = YES;
		msaaEnabled = NO;
		msaaSamples = 2;
	}
	return self;
}

- (void)dealloc {
	// Make sure this rendering context is the current one, so all
	// OpenGL objects can be deleted properly.
	EAGLContext * oldContext = [EAGLContext currentContext];
	[EAGLContext setCurrentContext:glContext];
	
	[program2D release];
	[fontCache release];
	
	// Release all fonts and clip paths from the stack
	for( int i = 0; i < stateIndex + 1; i++ ) {
		[stateStack[i].font release];
		[stateStack[i].clipPath release];
	}
	
	if( viewFrameBuffer ) { glDeleteFramebuffers( 1, &viewFrameBuffer); }
	if( viewRenderBuffer ) { glDeleteRenderbuffers(1, &viewRenderBuffer); }
	if( msaaFrameBuffer ) {	glDeleteFramebuffers( 1, &msaaFrameBuffer); }
	if( msaaRenderBuffer ) { glDeleteRenderbuffers(1, &msaaRenderBuffer); }
	if( stencilBuffer ) { glDeleteRenderbuffers(1, &stencilBuffer); }
	
	[path release];
	[EAGLContext setCurrentContext:oldContext];
	
	[super dealloc];
}

- (void)create {
	if( msaaEnabled ) {
		glGenFramebuffers(1, &msaaFrameBuffer);
		glBindFramebuffer(GL_FRAMEBUFFER, msaaFrameBuffer);
		
		glGenRenderbuffers(1, &msaaRenderBuffer);
		glBindRenderbuffer(GL_RENDERBUFFER, msaaRenderBuffer);
		
		glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, msaaSamples, GL_RGBA8_OES, bufferWidth, bufferHeight);
		glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, msaaRenderBuffer);
	}
	
	glGenFramebuffers(1, &viewFrameBuffer);
	glBindFramebuffer(GL_FRAMEBUFFER, viewFrameBuffer);
	
	glGenRenderbuffers(1, &viewRenderBuffer);
	glBindRenderbuffer(GL_RENDERBUFFER, viewRenderBuffer);
	
	program2D = [[EJApp instance].glProgram2D retain];
}

- (void)createStencilBufferOnce {
	if( stencilBuffer ) { return; }
	
	glGenRenderbuffers(1, &stencilBuffer);
	glBindRenderbuffer(GL_RENDERBUFFER, stencilBuffer);
	if( msaaEnabled ) {
		glRenderbufferStorageMultisampleAPPLE(GL_RENDERBUFFER, msaaSamples, GL_DEPTH24_STENCIL8_OES, bufferWidth, bufferHeight);
	}
	else {
		glRenderbufferStorageOES(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, bufferWidth, bufferHeight);
	}
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, stencilBuffer);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, stencilBuffer);
	
	glBindRenderbuffer(GL_RENDERBUFFER, msaaEnabled ? msaaRenderBuffer : viewRenderBuffer );
	
	glClear(GL_STENCIL_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	glEnable(GL_DEPTH_TEST);
}

- (void)bindVertexBuffer {	
	glEnableVertexAttribArray(kEJGLProgram2DAttributePos);
	glVertexAttribPointer(kEJGLProgram2DAttributePos, 2, GL_FLOAT, GL_FALSE,
		sizeof(EJVertex), (char *)EJCanvasVertexBuffer + offsetof(EJVertex, pos));
	
	glEnableVertexAttribArray(kEJGLProgram2DAttributeUV);
	glVertexAttribPointer(kEJGLProgram2DAttributeUV, 2, GL_FLOAT, GL_FALSE,
		sizeof(EJVertex), (char *)EJCanvasVertexBuffer + offsetof(EJVertex, uv));

	glEnableVertexAttribArray(kEJGLProgram2DAttributeColor);
	glVertexAttribPointer(kEJGLProgram2DAttributeColor, 4, GL_UNSIGNED_BYTE, GL_TRUE,
		sizeof(EJVertex), (char *)EJCanvasVertexBuffer + offsetof(EJVertex, color));
}

- (void)prepare {
	// Bind the frameBuffer and vertexBuffer array
	glBindFramebuffer(GL_FRAMEBUFFER, msaaEnabled ? msaaFrameBuffer : viewFrameBuffer );
	glBindRenderbuffer(GL_RENDERBUFFER, msaaEnabled ? msaaRenderBuffer : viewRenderBuffer );
	
	glViewport(0, 0, bufferWidth, bufferHeight);
	
	EJCompositeOperation op = state->globalCompositeOperation;
	glBlendFunc( EJCompositeOperationFuncs[op].source, EJCompositeOperationFuncs[op].destination );
	currentTexture = nil;
	[EJTexture setSmoothScaling:imageSmoothingEnabled];
	
	glUseProgram(program2D.program);
	glUniform2f(program2D.scale, vertexScale.x, vertexScale.y);
	glUniform2f(program2D.translate, vertexTranslate.x, vertexTranslate.y);
	glUniform1i(program2D.textureFormat, 0);
	
	[self bindVertexBuffer];
	
	if( stencilBuffer ) {
		glEnable(GL_DEPTH_TEST);
	}
	else {
		glDisable(GL_DEPTH_TEST);
	}
	
	if( state->clipPath ) {
		glDepthFunc(GL_EQUAL);
	}
	else {
		glDepthFunc(GL_ALWAYS);
	}
}

- (void)setTexture:(EJTexture *)newTexture {
	if( currentTexture == newTexture ) { return; }
	
	[self flushBuffers];
	
	currentTexture = newTexture;
	[currentTexture bind];
	glUniform1i(program2D.textureFormat, currentTexture.format);
}

- (void)pushTriX1:(float)x1 y1:(float)y1 x2:(float)x2 y2:(float)y2
			   x3:(float)x3 y3:(float)y3
			color:(EJColorRGBA)color
	withTransform:(CGAffineTransform)transform
{
	if( vertexBufferIndex >= EJ_CANVAS_VERTEX_BUFFER_SIZE - 3 ) {
		[self flushBuffers];
	}
	
	EJVector2 d1 = { x1, y1 };
	EJVector2 d2 = { x2, y2 };
	EJVector2 d3 = { x3, y3 };
	
	if( !CGAffineTransformIsIdentity(transform) ) {
		d1 = EJVector2ApplyTransform( d1, transform );
		d2 = EJVector2ApplyTransform( d2, transform );
		d3 = EJVector2ApplyTransform( d3, transform );
	}
	
	EJVertex * vb = &EJCanvasVertexBuffer[vertexBufferIndex];
	vb[0] = (EJVertex) { d1, {0, 0}, color };
	vb[1] = (EJVertex) { d2, {0, 0}, color };
	vb[2] = (EJVertex) { d3, {0, 0}, color };
	
	vertexBufferIndex += 3;
}

- (void)pushQuadV1:(EJVector2)v1 v2:(EJVector2)v2 v3:(EJVector2)v3 v4:(EJVector2)v4
	color:(EJColorRGBA)color
	withTransform:(CGAffineTransform)transform
{
	if( vertexBufferIndex >= EJ_CANVAS_VERTEX_BUFFER_SIZE - 6 ) {
		[self flushBuffers];
	}
	
	if( !CGAffineTransformIsIdentity(transform) ) {
		v1 = EJVector2ApplyTransform( v1, transform );
		v2 = EJVector2ApplyTransform( v2, transform );
		v3 = EJVector2ApplyTransform( v3, transform );
		v4 = EJVector2ApplyTransform( v4, transform );
	}
	
	EJVertex * vb = &EJCanvasVertexBuffer[vertexBufferIndex];
	vb[0] = (EJVertex) { v1, {0, 0}, color };
	vb[1] = (EJVertex) { v2, {0, 0}, color };
	vb[2] = (EJVertex) { v3, {0, 0}, color };
	vb[3] = (EJVertex) { v2, {0, 0}, color };
	vb[4] = (EJVertex) { v3, {0, 0}, color };
	vb[5] = (EJVertex) { v4, {0, 0}, color };
	
	vertexBufferIndex += 6;
}

- (void)pushRectX:(float)x y:(float)y w:(float)w h:(float)h
	color:(EJColorRGBA)color
	withTransform:(CGAffineTransform)transform
{
	if( vertexBufferIndex >= EJ_CANVAS_VERTEX_BUFFER_SIZE - 6 ) {
		[self flushBuffers];
	}
		
	EJVector2 d11 = {x, y};
	EJVector2 d21 = {x+w, y};
	EJVector2 d12 = {x, y+h};
	EJVector2 d22 = {x+w, y+h};
	
	if( !CGAffineTransformIsIdentity(transform) ) {
		d11 = EJVector2ApplyTransform( d11, transform );
		d21 = EJVector2ApplyTransform( d21, transform );
		d12 = EJVector2ApplyTransform( d12, transform );
		d22 = EJVector2ApplyTransform( d22, transform );
	}
	
	EJVertex * vb = &EJCanvasVertexBuffer[vertexBufferIndex];
	vb[0] = (EJVertex) { d11, {0, 0}, color };	// top left
	vb[1] = (EJVertex) { d21, {0, 0}, color };	// top right
	vb[2] = (EJVertex) { d12, {0, 0}, color };	// bottom left
		
	vb[3] = (EJVertex) { d21, {0, 0}, color };	// top right
	vb[4] = (EJVertex) { d12, {0, 0}, color };	// bottom left
	vb[5] = (EJVertex) { d22, {0, 0}, color };	// bottom right
	
	vertexBufferIndex += 6;
}

- (void)pushTexturedRectX:(float)x y:(float)y w:(float)w h:(float)h
	tx:(float)tx ty:(float)ty tw:(float)tw th:(float)th
	color:(EJColorRGBA)color
	withTransform:(CGAffineTransform)transform
{
	if( vertexBufferIndex >= EJ_CANVAS_VERTEX_BUFFER_SIZE - 6 ) {
		[self flushBuffers];
	}
	
	EJVector2 d11 = {x, y};
	EJVector2 d21 = {x+w, y};
	EJVector2 d12 = {x, y+h};
	EJVector2 d22 = {x+w, y+h};
	
	if( !CGAffineTransformIsIdentity(transform) ) {
		d11 = EJVector2ApplyTransform( d11, transform );
		d21 = EJVector2ApplyTransform( d21, transform );
		d12 = EJVector2ApplyTransform( d12, transform );
		d22 = EJVector2ApplyTransform( d22, transform );
	}

	EJVertex * vb = &EJCanvasVertexBuffer[vertexBufferIndex];
	vb[0] = (EJVertex) { d11, {tx, ty}, color };	// top left
	vb[1] = (EJVertex) { d21, {tx+tw, ty}, color };	// top right
	vb[2] = (EJVertex) { d12, {tx, ty+th}, color };	// bottom left
		
	vb[3] = (EJVertex) { d21, {tx+tw, ty}, color };	// top right
	vb[4] = (EJVertex) { d12, {tx, ty+th}, color };	// bottom left
	vb[5] = (EJVertex) { d22, {tx+tw, ty+th}, color };	// bottom right
	
	vertexBufferIndex += 6;
}

- (void)flushBuffers {
	if( vertexBufferIndex == 0 ) { return; }
	
	glDrawArrays(GL_TRIANGLES, 0, vertexBufferIndex);
	vertexBufferIndex = 0;
}

- (void)setImageSmoothingEnabled:(BOOL)enabled {
	[self setTexture:NULL];
	imageSmoothingEnabled = enabled;
	[EJTexture setSmoothScaling:enabled];
}

- (void)setGlobalCompositeOperation:(EJCompositeOperation)op {
	[self flushBuffers];
	glBlendFunc( EJCompositeOperationFuncs[op].source, EJCompositeOperationFuncs[op].destination );
	state->globalCompositeOperation = op;
}

- (EJCompositeOperation)globalCompositeOperation {
	return state->globalCompositeOperation;
}

- (void)setFont:(UIFont *)font {
	[state->font release];
	state->font = [font retain];
}

- (UIFont *)font {
	return state->font;
}


- (void)save {
	if( stateIndex == EJ_CANVAS_STATE_STACK_SIZE-1 ) {
		NSLog(@"Warning: EJ_CANVAS_STATE_STACK_SIZE (%d) reached", EJ_CANVAS_STATE_STACK_SIZE);
		return;
	}
	
	stateStack[stateIndex+1] = stateStack[stateIndex];
	stateIndex++;
	state = &stateStack[stateIndex];
	[state->font retain];
	[state->clipPath retain];
}

- (void)restore {
	if( stateIndex == 0 ) {	return; }
	
	EJCompositeOperation oldCompositeOp = state->globalCompositeOperation;
	EJPath * oldClipPath = state->clipPath;
	
	// Clean up current state
	[state->font release];

	if( state->clipPath && state->clipPath != stateStack[stateIndex-1].clipPath ) {
		[self resetClip];
	}
	[state->clipPath release];
	
	// Load state from stack
	stateIndex--;
	state = &stateStack[stateIndex];
	
    path.transform = state->transform;
    
	// Set Composite op, if different
	if( state->globalCompositeOperation != oldCompositeOp ) {
		self.globalCompositeOperation = state->globalCompositeOperation;
	}
	
	// Render clip path, if present and different
	if( state->clipPath && state->clipPath != oldClipPath ) {
		[state->clipPath drawPolygonsToContext:self target:kEJPathPolygonTargetDepth];
	}
}

- (void)rotate:(float)angle {
	state->transform = CGAffineTransformRotate( state->transform, angle );
    path.transform = state->transform;
}

- (void)translateX:(float)x y:(float)y {
	state->transform = CGAffineTransformTranslate( state->transform, x, y );
    path.transform = state->transform;
}

- (void)scaleX:(float)x y:(float)y {
	state->transform = CGAffineTransformScale( state->transform, x, y );
	path.transform = state->transform;
}

- (void)transformM11:(float)m11 m12:(float)m12 m21:(float)m21 m22:(float)m22 dx:(float)dx dy:(float)dy {
	CGAffineTransform t = CGAffineTransformMake( m11, m12, m21, m22, dx, dy );
	state->transform = CGAffineTransformConcat( t, state->transform );
	path.transform = state->transform;
}

- (void)setTransformM11:(float)m11 m12:(float)m12 m21:(float)m21 m22:(float)m22 dx:(float)dx dy:(float)dy {
	state->transform = CGAffineTransformMake( m11, m12, m21, m22, dx, dy );
	path.transform = state->transform;
}

- (void)drawImage:(EJTexture *)texture sx:(float)sx sy:(float)sy sw:(float)sw sh:(float)sh dx:(float)dx dy:(float)dy dw:(float)dw dh:(float)dh {
	
	float tw = texture.width;
	float th = texture.height;
	
	EJColorRGBA color = {.rgba = {255, 255, 255, 255 * state->globalAlpha}};
	[self setTexture:texture];
	[self pushTexturedRectX:dx y:dy w:dw h:dh tx:sx/tw ty:sy/th tw:sw/tw th:sh/th color:color withTransform:state->transform];
}

- (void)fillRectX:(float)x y:(float)y w:(float)w h:(float)h {
	[self setTexture:NULL];
	
	EJColorRGBA color = state->fillColor;
	color.rgba.a = (float)color.rgba.a * state->globalAlpha;
	[self pushRectX:x y:y w:w h:h color:color withTransform:state->transform];
}

- (void)strokeRectX:(float)x y:(float)y w:(float)w h:(float)h {
	// strokeRect should not affect the current path, so we create
	// a new, tempPath instead.
	EJPath * tempPath = [[EJPath alloc] init];
	tempPath.transform = state->transform;
	
	[tempPath moveToX:x y:y];
	[tempPath lineToX:x+w y:y];
	[tempPath lineToX:x+w y:y+h];
	[tempPath lineToX:x y:y+h];
	[tempPath close];
	
	[tempPath drawLinesToContext:self];
	[tempPath release];
}

- (void)clearRectX:(float)x y:(float)y w:(float)w h:(float)h {
	[self setTexture:NULL];
	
	EJCompositeOperation oldOp = state->globalCompositeOperation;
	self.globalCompositeOperation = kEJCompositeOperationDestinationOut;
	
	static EJColorRGBA white = {.hex = 0xffffffff};
	[self pushRectX:x y:y w:w h:h color:white withTransform:state->transform];
	
	self.globalCompositeOperation = oldOp;
}

- (EJImageData*)getImageDataScaled:(float)scale flipped:(bool)flipped sx:(short)sx sy:(short)sy sw:(short)sw sh:(short)sh {
	
	[self flushBuffers];
	
	NSMutableData * pixels;
	
	// Fast case - no scaling, no flipping
	if( scale == 1 && !flipped ) {
		pixels = [NSMutableData dataWithLength:sw * sh * 4 * sizeof(GLubyte)];
		glReadPixels(sx, sy, sw, sh, GL_RGBA, GL_UNSIGNED_BYTE, pixels.mutableBytes);
	}
	
	// More processing needed - take care of the flipped screen layout and the scaling
	else {
		int internalWidth = sw * scale;
		int internalHeight = sh * scale;
		int internalX = sx * scale;
		int internalY = (height-sy-sh) * scale;
		
		EJColorRGBA * internalPixels = malloc( internalWidth * internalHeight * sizeof(EJColorRGBA));
		glReadPixels( internalX, internalY, internalWidth, internalHeight, GL_RGBA, GL_UNSIGNED_BYTE, internalPixels );
		
		int size = sw * sh * sizeof(EJColorRGBA);
		EJColorRGBA * scaledPixels = malloc( size );
		int index = 0;
		for( int y = 0; y < sh; y++ ) {
			int rowIndex = (int)((flipped ? sh-y-1 : y) * scale) * internalWidth;
			for( int x = 0; x < sw; x++ ) {
				int internalIndex = rowIndex + (int)(x * scale);
				scaledPixels[ index ] = internalPixels[ internalIndex ];
				index++;
			}
		}
		free(internalPixels);
	
		pixels = [NSMutableData dataWithBytesNoCopy:scaledPixels length:size];
	}
	
	return [[[EJImageData alloc] initWithWidth:sw height:sh pixels:pixels] autorelease];
}

- (EJImageData*)getImageDataSx:(short)sx sy:(short)sy sw:(short)sw sh:(short)sh {
	return [self getImageDataScaled:backingStoreRatio flipped:NO sx:sx sy:sy sw:sw sh:sh];
}

- (EJImageData*)getImageDataHDSx:(short)sx sy:(short)sy sw:(short)sw sh:(short)sh {
	return [self getImageDataScaled:1 flipped:NO sx:sx sy:sy sw:sw sh:sh];
}

- (void)putImageData:(EJImageData*)imageData scaled:(float)scale dx:(float)dx dy:(float)dy {
	EJTexture * texture = imageData.texture;
	[self setTexture:texture];
	
	short tw = texture.width / scale;
	short th = texture.height / scale;
	
	static EJColorRGBA white = {.hex = 0xffffffff};
	
	[self pushTexturedRectX:dx y:dy w:tw h:th tx:0 ty:0 tw:1 th:1 color:white withTransform:CGAffineTransformIdentity];
	[self flushBuffers];
}

- (void)putImageData:(EJImageData*)imageData dx:(float)dx dy:(float)dy {
	[self putImageData:imageData scaled:1 dx:dx dy:dy];
}

- (void)putImageDataHD:(EJImageData*)imageData dx:(float)dx dy:(float)dy {
	[self putImageData:imageData scaled:backingStoreRatio dx:dx dy:dy];
}

- (void)beginPath {
	[path reset];
}

- (void)closePath {
	[path close];
}

- (void)fill {	
	[path drawPolygonsToContext:self target:kEJPathPolygonTargetColor];
}

- (void)stroke {
	[path drawLinesToContext:self];
}

- (void)moveToX:(float)x y:(float)y {
	[path moveToX:x y:y];
}

- (void)lineToX:(float)x y:(float)y {
	[path lineToX:x y:y];
}

- (void)bezierCurveToCpx1:(float)cpx1 cpy1:(float)cpy1 cpx2:(float)cpx2 cpy2:(float)cpy2 x:(float)x y:(float)y {
	float scale = CGAffineTransformGetScale( state->transform );
	[path bezierCurveToCpx1:cpx1 cpy1:cpy1 cpx2:cpx2 cpy2:cpy2 x:x y:y scale:scale];
}

- (void)quadraticCurveToCpx:(float)cpx cpy:(float)cpy x:(float)x y:(float)y {
	float scale = CGAffineTransformGetScale( state->transform );
	[path quadraticCurveToCpx:cpx cpy:cpy x:x y:y scale:scale];
}

- (void)rectX:(float)x y:(float)y w:(float)w h:(float)h {
	[path moveToX:x y:y];
	[path lineToX:x+w y:y];
	[path lineToX:x+w y:y+h];
	[path lineToX:x y:y+h];
	[path close];
}

- (void)arcToX1:(float)x1 y1:(float)y1 x2:(float)x2 y2:(float)y2 radius:(float)radius {
	[path arcToX1:x1 y1:y1 x2:x2 y2:y2 radius:radius];
}

- (void)arcX:(float)x y:(float)y radius:(float)radius
	startAngle:(float)startAngle endAngle:(float)endAngle
	antiClockwise:(BOOL)antiClockwise
{
	[path arcX:x y:y radius:radius startAngle:startAngle endAngle:endAngle antiClockwise:antiClockwise];
}

- (EJFont*)acquireFont:(NSString*)fontName size:(float)pointSize fill:(BOOL)fill contentScale:(float)contentScale {
	NSString * cacheKey = [NSString stringWithFormat:@"%@_%.2f_%d_%.2f", fontName, pointSize, fill, contentScale];
	EJFont * font = [fontCache objectForKey:cacheKey];
	if( !font ) {
		font = [[EJFont alloc] initWithFont:fontName size:pointSize fill:fill contentScale:contentScale];
		[fontCache setObject:font forKey:cacheKey];
		[font autorelease];
	}
	return font;
}

- (void)fillText:(NSString *)text x:(float)x y:(float)y {
	EJFont *font = [self acquireFont:state->font.fontName size:state->font.pointSize fill:YES contentScale:backingStoreRatio];
	[font drawString:text toContext:self x:x y:y];
}

- (void)strokeText:(NSString *)text x:(float)x y:(float)y {
	EJFont *font = [self acquireFont:state->font.fontName size:state->font.pointSize fill:NO contentScale:backingStoreRatio];
	[font drawString:text toContext:self x:x y:y];
}

- (float)measureText:(NSString *)text {
	EJFont *font = [self acquireFont:state->font.fontName size:state->font.pointSize fill:YES contentScale:backingStoreRatio];
	return [font measureString:text];
}

- (void)clip {
	[self flushBuffers];
	[state->clipPath release];
	state->clipPath = nil;
	
	state->clipPath = [path copy];
	[state->clipPath drawPolygonsToContext:self target:kEJPathPolygonTargetDepth];
}

- (void)resetClip {
	if( state->clipPath ) {
		[self flushBuffers];
		[state->clipPath release];
		state->clipPath = nil;
		
		glDepthMask(GL_TRUE);
		glClear(GL_DEPTH_BUFFER_BIT);
		glDepthMask(GL_FALSE);
		glDepthFunc(GL_ALWAYS);
	}
}

@end
