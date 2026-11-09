import { audioSource } from './model.mjs';

export class VoiceController {
  constructor({ invoke, action, settings, onState, onText, onReply, onError }) {
    Object.assign(this, { invoke, action, settings, onState, onText, onReply, onError });
    this.generation = 0;
    this.audio = null;
    this.calling = false;
    this.listening = false;
    this.speaking = false;
    this.currentUserText = '';
    this.currentReplyId = null;
    this.turnStarted = false;
    this.replyPending = false;
    this.resetStream();
  }

  async stop() {
    this.generation += 1;
    this.resetStream();
    this.currentUserText = '';
    this.currentReplyId = null;
    this.replyPending = false;
    const wasCalling = this.calling;
    this.calling = false;
    this.listening = false;
    this.speaking = false;
    if (this.audio) { this.audio.pause(); this.audio.src = ''; this.audio = null; }
    await Promise.allSettled([
      this.invoke('desktop_stop_speech'),
      this.invoke('desktop_platform', { action: 'listen_stop', payload: {} }),
      this.action('voice_ended', {}),
      ...(wasCalling ? [this.action('voice_call_ended', {}), this.action('chat_cancel', {})] : []),
    ]);
    this.onState('idle');
  }

  async listenOnce() {
    if (this.listening || this.calling) return this.stop();
    if (this.speaking) await this.stop();
    const generation = ++this.generation;
    this.listening = true;
    this.onState('listening');
    try {
      const result = await this.invoke('desktop_listen', { language: this.recognitionLanguage() });
      if (generation !== this.generation) return;
      const text = typeof result === 'string' ? result : result?.text || result?.transcript || '';
      if (text.trim()) this.onText(text.trim());
    } catch (error) {
      if (generation === this.generation) this.onError(error);
    } finally {
      if (generation === this.generation) { this.listening = false; this.onState('idle'); }
    }
  }

  language() { return this.settings().replyLanguage || 'auto'; }
  recognitionLanguage() { return this.settings().speechRecognitionLanguage || this.language(); }

  async speak(text, language = this.language(), generation = this.generation, { fromCall = false } = {}) {
    if (!text || generation !== this.generation) return;
    if (this.speaking || this.listening || this.calling && !fromCall) { await this.stop(); generation = this.generation; }
    const settings = this.settings();
    const provider = settings.speechProvider || settings.ttsProvider || 'system';
    if (provider === 'none' || provider === 'disabled' || provider === 'off') throw new Error('voice-not-configured');
    this.speaking = true;
    this.onState('speaking');
    let jobId;
    try {
      if (provider === 'local' || provider === 'localTTS' || provider === 'http') {
        const data = await this.action('voice_request', { text, language });
        jobId = data?.jobId;
        if (generation !== this.generation) return;
        const source = audioSource(data);
        if (!source) throw new Error('voice-audio-missing');
        const audio = new Audio(source);
        this.audio = audio;
        await new Promise((resolve, reject) => {
          let started = false;
          audio.addEventListener('playing', () => {
            if (!started && generation === this.generation) {
              started = true;
              if (fromCall) this.turnStarted = true;
              void this.action('voice_started', { text, duration: Number.isFinite(audio.duration) ? audio.duration : 0, jobId }).catch(this.onError);
            }
          });
          audio.addEventListener('ended', resolve, { once: true });
          audio.addEventListener('pause', () => { if (generation !== this.generation) resolve(); });
          audio.addEventListener('error', () => reject(new Error('voice-playback-failed')), { once: true });
          audio.play().catch(reject);
        });
        if (this.audio === audio) this.audio = null;
      } else {
        const result = await this.invoke('desktop_speak', { text, language });
        jobId = result?.jobId ?? result?.id;
        if (generation !== this.generation) return;
        if (!jobId) throw new Error('voice-playback-failed');
        if (jobId && generation === this.generation) {
          let started = false;
          const deadline = Date.now() + 180000;
          while (generation === this.generation && Date.now() < deadline) {
            const status = await this.invoke('desktop_platform', { action: 'speak_status', payload: { jobId } });
            const phase = status?.status || status?.state;
            if (phase === 'failed') throw new Error(status?.error || 'voice-playback-failed');
            if ((phase === 'speaking' || status?.event === 'voice-start') && !started) { started = true; if (fromCall) this.turnStarted = true; await this.action('voice_started', { text, duration: 0, jobId }); }
            if (phase === 'completed' || phase === 'stopped' || phase === 'cancelled' || status?.completed === true) break;
            await new Promise(resolve => setTimeout(resolve, 200));
          }
          if (generation === this.generation && Date.now() >= deadline) throw new Error('voice-playback-failed');
        }
      }
    } finally {
      if (generation === this.generation) {
        this.speaking = false;
        if (jobId !== undefined && jobId !== null) await this.action('voice_ended', { jobId }).catch(() => {});
        this.onState(this.calling ? this.replyPending ? 'thinking' : 'listening' : 'idle');
      }
    }
  }

  resetStream(generation = null) {
    this.streamGeneration = generation;
    this.currentVoiceTurnId = null;
    this.streamSequence = 0;
    this.streamCharacters = 0;
    this.streamCompletedText = '';
    this.turnStarted = false;
    this.streamQueue = Promise.resolve();
  }

  enqueueSegment(segment) {
    const generation = segment?.voiceGeneration;
    if (!this.calling || generation !== this.generation || generation !== this.streamGeneration) return;
    if (this.currentVoiceTurnId && segment.voiceTurnId !== this.currentVoiceTurnId) return;
    if (!Number.isSafeInteger(segment.sequence) || segment.sequence < this.streamSequence) return;
    if (segment.sequence !== this.streamSequence || typeof segment.voiceTurnId !== 'string' || !segment.voiceTurnId || segment.voiceTurnId.length > 128 || typeof segment.text !== 'string' || !segment.text.trim()
      || this.streamSequence >= 32 || this.streamCharacters + Array.from(segment.text).length > 16000) {
      this.onError(new Error('voice-stream-invalid'));
      void this.stop();
      return;
    }
    this.currentVoiceTurnId = segment.voiceTurnId;
    this.streamSequence += 1;
    this.streamCharacters += Array.from(segment.text).length;
    this.streamQueue = this.streamQueue.then(async () => {
      if (!this.calling || generation !== this.generation) return;
      await this.speak(segment.text, segment.language || this.language(), generation, { fromCall: true });
      if (generation === this.generation) { this.streamCompletedText += segment.text; this.turnStarted = true; }
    }).catch(error => {
      if (generation !== this.generation) return;
      this.onError(error);
      void this.stop();
    });
  }

  async drainStream(generation) {
    let queued;
    do { queued = this.streamQueue; await queued; }
    while (generation === this.generation && queued !== this.streamQueue);
  }

  async interruptAndListen() {
    if (!this.calling) return;
    const payload = { voiceGeneration: this.generation, voiceTurnId: this.currentVoiceTurnId, completedText: this.streamCompletedText, started: this.turnStarted, replyId: this.currentReplyId, userText: this.currentUserText };
    const stopping = this.stop();
    const generation = this.generation;
    await Promise.all([stopping, this.action('voice_call_interrupt', payload)]);
    if (generation !== this.generation) return;
    return this.startCall();
  }

  async startCall() {
    if (this.calling) return this.stop();
    if (this.speaking || this.listening) await this.stop();
    const generation = ++this.generation;
    this.calling = true;
    let started = false;
    try {
      await this.action('voice_call_started', {});
      started = true;
      while (this.calling && generation === this.generation) {
        this.listening = true;
        this.onState('listening');
        const result = await this.invoke('desktop_listen', { language: this.recognitionLanguage() });
        if (generation !== this.generation) break;
        this.listening = false;
        const text = typeof result === 'string' ? result : result?.text || result?.transcript || '';
        if (!text.trim()) continue;
        this.onText(text.trim(), true);
        this.currentUserText = text.trim();
        this.currentReplyId = null;
        this.replyPending = true;
        this.onState('thinking');
        this.resetStream(generation);
        const reply = await this.invoke('desktop_send_message', { text: text.trim(), image: null, voiceStream: true, voiceGeneration: generation });
        if (generation !== this.generation) break;
        this.replyPending = false;
        if (reply.voiceTurnId) {
          if (this.currentVoiceTurnId && this.currentVoiceTurnId !== reply.voiceTurnId) throw new Error('voice-stream-invalid');
          this.currentVoiceTurnId = reply.voiceTurnId;
        }
        this.currentReplyId = reply.id || null;
        this.onReply(reply);
        if (reply.voiceStreamed === true) {
          if (!this.streamSequence) throw new Error('voice-audio-missing');
          await this.drainStream(generation);
        } else {
          if (this.streamSequence) throw new Error('voice-stream-invalid');
          await this.speak(reply.text || reply.content || '', reply.language || this.language(), generation, { fromCall: true });
          if (generation === this.generation) { this.streamCompletedText = reply.text || reply.content || ''; this.turnStarted = true; }
        }
      }
    } catch (error) {
      if (generation === this.generation) this.onError(error);
    } finally {
      if (generation === this.generation) {
        if (started) await this.stop();
        else { this.calling = false; this.listening = false; this.resetStream(); this.onState('idle'); }
      }
    }
  }
}
