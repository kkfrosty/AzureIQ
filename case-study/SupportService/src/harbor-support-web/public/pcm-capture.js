// Resample from the actual device rate, preserving phase across render quanta.
class HarborPcmCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.phase = 0;
    this.previous = 0;
    this.chunk = new Int16Array(1200);
    this.offset = 0;
  }

  process(inputs) {
    const channel = inputs[0]?.[0];
    if (!channel) return true;
    const step = sampleRate / 24000;
    while (this.phase < channel.length) {
      const left = Math.floor(this.phase);
      const fraction = this.phase - left;
      const before = left === 0 ? this.previous : channel[left - 1];
      const after = channel[left];
      const sample = Math.max(-1, Math.min(1, before + (after - before) * fraction));
      this.chunk[this.offset++] = Math.round(sample * (sample < 0 ? 32768 : 32767));
      if (this.offset === this.chunk.length) {
        this.port.postMessage(this.chunk.buffer, [this.chunk.buffer]);
        this.chunk = new Int16Array(1200);
        this.offset = 0;
      }
      this.phase += step;
    }
    this.phase -= channel.length;
    this.previous = channel[channel.length - 1];
    return true;
  }
}

registerProcessor('harbor-pcm-capture', HarborPcmCapture);
