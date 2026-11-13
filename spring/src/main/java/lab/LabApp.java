// 랩용 Spring Boot 앱. Go 앱(app/main.go)과 같은 엔드포인트를 Tomcat 동기 서블릿으로 낸다.
// 다운로드는 요청 스레드가 응답 출력 스트림에 직접 쓴다 (운영 다운로드 컨트롤러와 같은 방식).
package lab;

import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.util.concurrent.atomic.AtomicLong;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class LabApp {

  private static final String VERSION = System.getenv().getOrDefault("VERSION", "v1");
  private static final int CHUNK = 64 * 1024;
  private final AtomicLong inflight = new AtomicLong();
  private final String host;

  public LabApp() throws IOException {
    host = InetAddress.getLocalHost().getHostName();
  }

  public static void main(String[] args) {
    SpringApplication.run(LabApp.class, args);
  }

  @GetMapping("/health")
  String health() {
    return "ok";
  }

  @GetMapping("/inflight")
  String inflight() {
    return inflight.get() + "\n";
  }

  @GetMapping("/version")
  String version(HttpServletResponse res) {
    res.setHeader("X-Version", VERSION);
    res.setHeader("X-Host", host);
    return VERSION + " " + host + "\n";
  }

  // /download?size=<바이트>&rate=<바이트/초>: size 바이트를 rate 속도로 64KiB 씩 보낸다
  @GetMapping("/download")
  void download(@RequestParam long size, @RequestParam long rate, HttpServletResponse res)
      throws IOException, InterruptedException {
    inflight.incrementAndGet();
    try {
      res.setContentType("application/octet-stream");
      res.setContentLengthLong(size);
      res.setHeader("X-Version", VERSION);
      res.setHeader("X-Host", host);
      OutputStream out = res.getOutputStream();
      byte[] buf = new byte[CHUNK];
      long start = System.nanoTime();
      long sent = 0;
      while (sent < size) {
        int n = (int) Math.min(CHUNK, size - sent);
        out.write(buf, 0, n);
        out.flush();
        sent += n;
        // 누적 기준으로 속도를 맞춘다: sent 바이트를 보냈어야 할 시각까지 기다린다
        long due = start + (long) (sent * 1e9 / rate);
        long wait = due - System.nanoTime();
        if (wait > 0) {
          Thread.sleep(wait / 1_000_000, (int) (wait % 1_000_000));
        }
      }
    } finally {
      inflight.decrementAndGet();
    }
  }
}
