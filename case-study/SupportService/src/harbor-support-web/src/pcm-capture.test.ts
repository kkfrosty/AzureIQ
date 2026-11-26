import { runInNewContext } from 'node:vm';
import { describe, expect, it } from 'vitest';
import workletSource from '../public/pcm-capture.js?raw';

interface Processor {
  process(inputs: Float32Array[][]): boolean;
}

describe('microphone PCM worklet', () => {
  it.each([24000, 44100, 48000])('resamples %i Hz to bounded 24 kHz mono PCM16 chunks', deviceRate => {
    const chunks: ArrayBuffer[] = [];
    let ProcessorConstructor: (new () => Processor) | undefined;
    class BaseProcessor {
      port = { postMessage: (buffer: ArrayBuffer) => chunks.push(buffer) };
    }
    runInNewContext(workletSource, {
      AudioWorkletProcessor: BaseProcessor, sampleRate: deviceRate,
      registerProcessor: (_name: string, constructor: new () => Processor) => { ProcessorConstructor = constructor; },
    });
    if (!ProcessorConstructor) throw new Error('Worklet was not registered');
    const processor = new ProcessorConstructor();
    const frames = Math.ceil(deviceRate / 128);
    for (let frame = 0; frame < frames; frame++) {
      expect(processor.process([[new Float32Array(128).fill(0.5)]])).toBe(true);
    }
    expect(chunks).toHaveLength(20);
    expect(chunks.every(chunk => chunk.byteLength === 2400)).toBe(true);
    const chunk = chunks[1];
    if (!chunk) throw new Error('Expected captured audio');
    const samples = new Int16Array(chunk);
    expect(samples[0]).toBe(16384);
  });
});
