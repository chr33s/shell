declare module "qrcode-terminal" {
  const qrcode: {
    generate(text: string, options?: { small?: boolean }, callback?: () => void): void;
  };
  export default qrcode;
}
