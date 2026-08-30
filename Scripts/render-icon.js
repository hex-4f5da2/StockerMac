var iconImg = sips.images[0];
var canvas = new Canvas(1024, 1024);

// Function to draw standard macOS rounded rectangle
function roundedRect(ctx, x, y, width, height, radius) {
    ctx.beginPath();
    ctx.moveTo(x + radius, y);
    ctx.lineTo(x + width - radius, y);
    ctx.arcTo(x + width, y, x + width, y + radius, radius);
    ctx.lineTo(x + width, y + height - radius);
    ctx.arcTo(x + width, y + height, x + width - radius, y + height, radius);
    ctx.lineTo(x + radius, y + height);
    ctx.arcTo(x, y + height, x, y + height - radius, radius);
    ctx.lineTo(x, y + radius);
    ctx.arcTo(x, y, x + radius, y, radius);
    ctx.closePath();
}

var size = 824;
var offset = 100;
var radius = 185;

// 1. Ambient Drop Shadow (Soft, diffused downward macOS ambient shadow)
canvas.save();
canvas.shadowColor = "rgba(0, 0, 0, 0.18)";
canvas.shadowBlur = 32;
canvas.shadowOffsetX = 0;
canvas.shadowOffsetY = 16;
roundedRect(canvas, offset, offset, size, size, radius);
canvas.fillStyle = "rgba(0, 0, 0, 1.0)";
canvas.fill();
canvas.restore();

// 2. Key / Contact Shadow (Tight, darker contact shadow right beneath squircle)
canvas.save();
canvas.shadowColor = "rgba(0, 0, 0, 0.12)";
canvas.shadowBlur = 10;
canvas.shadowOffsetX = 0;
canvas.shadowOffsetY = 4;
roundedRect(canvas, offset, offset, size, size, radius);
canvas.fillStyle = "rgba(0, 0, 0, 1.0)";
canvas.fill();
canvas.restore();

// 3. Single Pure Squircle Base Plate (Without any nested borders or frames)
canvas.save();
roundedRect(canvas, offset, offset, size, size, radius);
canvas.clip();

// Clean Apple squircle gradient: subtle top-to-bottom white (#FFFFFF -> #F0F2F6)
var grad = canvas.createLinearGradient(0, offset, 0, offset + size);
grad.addColorStop(0.0, "#FFFFFF");
grad.addColorStop(1.0, "#F0F2F6");
canvas.fillStyle = grad;
canvas.fillRect(offset, offset, size, size);

// Draw the transparent paper airplane glyph centered
var glyphSize = 512;
var glyphOffset = (1024 - glyphSize) / 2; // 256
canvas.drawImage(iconImg, glyphOffset, glyphOffset, glyphSize, glyphSize);

canvas.restore();

// 4. Single delicate 1px hairline outer stroke
canvas.save();
roundedRect(canvas, offset, offset, size, size, radius);
canvas.strokeStyle = "rgba(0, 0, 0, 0.08)";
canvas.lineWidth = 1.0;
canvas.stroke();
canvas.restore();

var out = new Output(canvas, "AppIcon");
out.addToQueue();
